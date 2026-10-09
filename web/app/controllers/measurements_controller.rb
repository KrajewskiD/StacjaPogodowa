class MeasurementsController < ApplicationController
  skip_forgery_protection

  # Przyjmuje pomiary z ESP przez HTTPS. Dostęp wyłącznie po tokenie urządzenia
  # (ENV["INGEST_TOKEN"], stało-czasowe porównanie). Współdzieli walidację i zapis
  # z odbiorcą UDP (script/receive.rb): Measurement.ingest! + Gateway.observe! +
  # WeatherAlert.evaluate! w jednej transakcji.
  def create
    return head(:service_unavailable) if expected_token.blank?
    unless token_ok?(request.headers["Authorization"])
      return render json: { error: "Nieprawidłowy token" }, status: :unauthorized
    end

    raw = request.raw_post
    return render json: { error: "Pusty payload" }, status: :bad_request if raw.blank?
    if raw.bytesize > IngestPolicy::MAX_PAYLOAD_BYTES
      return render json: { error: "Zbyt duży payload" }, status: :payload_too_large
    end

    data = begin
      JSON.parse(raw)
    rescue JSON::ParserError
      return render json: { error: "Niepoprawny JSON" }, status: :bad_request
    end

    measurement = nil
    Measurement.transaction do
      measurement = Measurement.ingest!(data, source_ip: request.remote_ip)
      Gateway.observe!(data, source_ip: request.remote_ip)
      WeatherAlert.evaluate!(measurement, settings: StationSetting.current) if measurement
    end

    if measurement
      render json: { id: measurement.id, sensor_id: measurement.sensor_id }, status: :created
    else
      # Wiadomość status (diagnostyka) — zapisano w Gateway, nie ma pomiaru pogody.
      render json: { status: "ok" }, status: :accepted
    end
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def expected_token
    ENV["INGEST_TOKEN"].to_s
  end

  def token_ok?(header)
    provided = header.to_s.delete_prefix("Bearer ").strip
    provided.present? &&
      ActiveSupport::SecurityUtils.secure_compare(provided, expected_token)
  end
end