import importlib.util
import json
from pathlib import Path
import select
import socket
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("receiver", ROOT / "receiver.py")
receiver = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receiver)


class ReceiverTests(unittest.TestCase):
    def test_invalid_packets(self):
        for raw in (b"broken", b"[]", b'{}', b'\xff',
                    b'{"schema":1,"type":"weather","sensor_id":"00001234",'
                    b'"temperature_c":NaN}',
                    b'{"schema":1,"type":"weather","sensor_id":"00001234",'
                    b'"humidity_pct":true}'):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                receiver.decode_packet(raw)

    def test_partial_frame_does_not_invent_measurements(self):
        data = receiver.decode_packet(json.dumps({
            "schema": 1, "type": "weather", "sensor_id": "00001234",
            "rain_total_mm": 12.5,
        }))
        text = receiver.display(data, "127.0.0.1")
        self.assertIn("12.5 mm", text)
        self.assertNotIn("Temperatura", text)
        self.assertNotIn("Bateria", text)

    def test_udp_delivery_and_recovery_after_invalid_packet(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        process = subprocess.Popen(
            [sys.executable, str(ROOT / "receiver.py"), "--bind", "127.0.0.1",
             "--port", str(port), "--json", "--sensor-id", "1234"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        )
        try:
            self.assertTrue(select.select([process.stderr], [], [], 5)[0])
            self.assertIn("Nasłuch", process.stderr.readline())
            data = {"schema": 1, "type": "weather", "sensor_id": "00001234",
                    "temperature_c": -2.3, "humidity_pct": 80}
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
                sender.sendto(b"not json", ("127.0.0.1", port))
                other = dict(data, sensor_id="00005678")
                sender.sendto(json.dumps(other).encode(), ("127.0.0.1", port))
                sender.sendto(json.dumps(data).encode(), ("127.0.0.1", port))
            self.assertTrue(select.select([process.stdout], [], [], 5)[0])
            self.assertEqual(json.loads(process.stdout.readline()), data)
            self.assertIsNone(process.poll())
        finally:
            process.terminate()
            process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main()
