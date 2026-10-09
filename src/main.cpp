#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESP8266WiFi.h>
#include <WiFiManager.h>
#include <WiFiUdp.h>
#include <ESP8266HTTPClient.h>
#include <WiFiClientSecureBearSSL.h>
#include <WeatherSensorCfg.h>
#include <WeatherSensor.h>
#include "config.h"

WeatherSensor weather;
WiFiManager wifiManager;
WiFiUDP udp;
BearSSL::WiFiClientSecure secureClient;
bool radioReady = false;
bool wasConnected = false;
uint32_t decodedPackets = 0;
uint32_t lastStatus = 0;
uint32_t lastWeather = 0;
uint32_t sequence = 0;
int16_t radioError = 0;

bool isTlsReady() {
    // Zakotwiczenie zaufania ustawiane raz; obiekt musi zyc przez caly czas.
    static BearSSL::X509List rootCert(ISRG_ROOT_X1);
    static bool configured = false;
    if (!configured) {
        secureClient.setTrustAnchors(&rootCert);
        configured = true;
    }
    return configured;
}

bool udpSend(const String &payload) {
    IPAddress destination((uint32_t)WiFi.localIP() | ~(uint32_t)WiFi.subnetMask());
    if (!udp.beginPacket(destination, UDP_PORT)) {
        Serial.println(F("UDP: nie mozna rozpoczac wysylania"));
        return false;
    }
    udp.write(reinterpret_cast<const uint8_t *>(payload.c_str()), payload.length());
    if (!udp.endPacket()) {
        Serial.println(F("UDP: blad wysylania"));
        return false;
    }
    return true;
}

bool httpsSend(const String &payload) {
    if (!isTlsReady()) {
        Serial.println(F("HTTPS: nie ustawiono zaufanego certyfikatu"));
        return false;
    }
    HTTPClient http;
    bool ok = false;
    if (http.begin(secureClient, SERVER_HOST, SERVER_PORT, SERVER_PATH, true)) {
        http.addHeader(F("Content-Type"), F("application/json"));
        http.addHeader(F("Authorization"), String(F("Bearer ")) + INGEST_TOKEN);
        int code = http.POST(reinterpret_cast<const uint8_t *>(payload.c_str()), payload.length());
        if (code < 0) {
            Serial.printf("HTTPS: blad polaczenia (%d) %s\n", code, http.errorToString(code).c_str());
        } else {
            ok = code >= 200 && code < 300;
            if (!ok) Serial.printf("HTTPS: status %d\n", code);
        }
        http.end();
    } else {
        Serial.println(F("HTTPS: nie mozna rozpoczac"));
    }
    return ok;
}

void emit(JsonDocument &doc) {
    doc["schema"] = 1;
    doc["device_id"] = String(ESP.getChipId(), HEX);
    doc["uptime_ms"] = millis();
    doc["seq"] = ++sequence;
    String payload;
    serializeJson(doc, payload);
    Serial.println(payload);
    if (WiFi.status() != WL_CONNECTED) return;
    // Pusty SERVER_HOST => lokalny UDP; w przeciwnym razie HTTPS do VPS.
    if (strlen(SERVER_HOST) > 0) {
        httpsSend(payload);
    } else {
        udpSend(payload);
    }
}

void sendWeather(const WeatherSensor::Sensor &sensor) {
    if (SENSOR_ID_FILTER && sensor.sensor_id != SENSOR_ID_FILTER) return;
    // Pozostale typy maja inny uklad unii danych (np. czujnik blyskawic).
    if (sensor.s_type != SENSOR_TYPE_WEATHER0 &&
        sensor.s_type != SENSOR_TYPE_WEATHER1 &&
        sensor.s_type != SENSOR_TYPE_WEATHER3 &&
        sensor.s_type != SENSOR_TYPE_WEATHER8 &&
        sensor.s_type != SENSOR_TYPE_THERMO_HYGRO &&
        sensor.s_type != SENSOR_TYPE_POOL_THERMO) return;

    JsonDocument doc;
    doc["type"] = "weather";
    char id[9];
    snprintf(id, sizeof(id), "%08lX", (unsigned long)sensor.sensor_id);
    doc["sensor_id"] = id;
    doc["sensor_type"] = sensor.s_type;
    doc["decoder"] = sensor.decoder;
    doc["channel"] = sensor.chan;
    doc["rssi_dbm"] = sensor.rssi;
    doc["complete"] = sensor.complete;
    doc["startup"] = sensor.startup;
    // W protokole 6-in-1 ramka deszczu nie zawiera stanu baterii.
    if (sensor.decoder != DECODER_6IN1 || sensor.w.temp_ok)
        doc["battery_ok"] = sensor.battery_ok;
    if (sensor.w.temp_ok) doc["temperature_c"] = sensor.w.temp_c;
    if (sensor.w.humidity_ok) doc["humidity_pct"] = sensor.w.humidity;
    if (sensor.w.wind_ok) {
        doc["wind_avg_ms"] = sensor.w.wind_avg_meter_sec;
        doc["wind_gust_ms"] = sensor.w.wind_gust_meter_sec;
        doc["wind_direction_deg"] = sensor.w.wind_direction_deg;
    }
    if (sensor.w.rain_ok) doc["rain_total_mm"] = sensor.w.rain_mm;
    if (sensor.w.uv_ok) doc["uv_index"] = sensor.w.uv;
    if (sensor.w.light_ok) doc["light_klx"] = sensor.w.light_klx;
    emit(doc);
    lastWeather = millis();
}

void setup() {
    Serial.begin(115200);
    pinMode(LED_BUILTIN, OUTPUT);
    digitalWrite(LED_BUILTIN, LOW); // Dioda D1 mini aktywna stanem niskim.
    Serial.println(F("\nStacjaPogodowa: ESP8266 + CC1101"));
    Serial.println(F("CS=D8 SCK=D5 MISO=D6 MOSI=D7 GDO0=D2 GDO2=D1"));
    Serial.println(F("Wyslij w przez port szeregowy, aby otworzyc konfiguracje Wi-Fi."));
    if (strlen(SERVER_HOST) > 0)
        Serial.printf("Transport: HTTPS %s:%u%s\n", SERVER_HOST, SERVER_PORT, SERVER_PATH);
    else
        Serial.printf("Transport: UDP %u (lokalny)\n", UDP_PORT);

    WiFi.mode(WIFI_STA);
    WiFi.hostname("stacja-pogodowa");
    WiFi.setAutoReconnect(true);
    wifiManager.setConfigPortalBlocking(false);
    wifiManager.setConnectTimeout(15);
    wifiManager.autoConnect(SETUP_SSID, SETUP_PASSWORD);

    // Bez zapisanych filtrow oraz przykladowego ID wykluczanego przez biblioteke.
    radioError = weather.begin(1, false, FREQUENCY_OFFSET_MHZ);
    radioReady = radioError == RADIOLIB_ERR_NONE;
    weather.enDecoders = DECODER_5IN1 | DECODER_6IN1 | DECODER_7IN1;
    Serial.printf("CC1101: %s (kod %d)\n", radioReady ? "OK" : "BLAD", radioError);
    lastStatus = millis() - 30000UL;
}

void loop() {
    wifiManager.process();
    if (Serial.available()) {
        char command = Serial.read();
        if (command == 'w' || command == 'W')
            wifiManager.startConfigPortal(SETUP_SSID, SETUP_PASSWORD);
    }
    bool connected = WiFi.status() == WL_CONNECTED;
    if (connected && !wasConnected) {
        if (strlen(SERVER_HOST) == 0) udp.begin(UDP_PORT);
        Serial.printf("Wi-Fi OK: %s\n", WiFi.localIP().toString().c_str());
        lastStatus = millis() - 30000UL;
    }
    wasConnected = connected;

    if (radioReady) {
        // Kazdy datagram zawiera tylko pomiary z aktualnej ramki.
        weather.clearSlots();
        if (weather.getMessage() == DECODE_OK) {
            ++decodedPackets;
            for (const auto &sensor : weather.sensor)
                if (sensor.valid) sendWeather(sensor);
        }
    }

    const uint32_t now = millis();
    // Swieci przy poprawnej inicjalizacji radia; miga przy bledzie radia.
    digitalWrite(LED_BUILTIN, radioReady ? LOW : ((now / 500) % 2 ? HIGH : LOW));
    if (now - lastStatus >= 30000UL) {
        lastStatus = now;
        JsonDocument doc;
        doc["type"] = "status";
        doc["radio_ok"] = radioReady;
        doc["radio_error"] = radioError;
        doc["frequency_mhz"] = 868.3 + FREQUENCY_OFFSET_MHZ;
        doc["decoded_packets"] = decodedPackets;
        if (lastWeather) doc["weather_age_s"] = (now - lastWeather) / 1000;
        doc["wifi_connected"] = connected;
        if (connected) doc["wifi_rssi_dbm"] = WiFi.RSSI();
        emit(doc);
    }
    delay(1);
}