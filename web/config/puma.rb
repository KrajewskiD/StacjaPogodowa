threads 1, 5
# Domyślnie pętla lokalna (bezpieczne przy Apache/systemd). W Dockerze ustaw
# PUMA_BIND=tcp://0.0.0.0:PORT, aby nginx w kontenerze mógł połączyć się z aplikacją.
bind ENV.fetch("PUMA_BIND", "tcp://127.0.0.1:3000")
environment ENV.fetch("RAILS_ENV", "production")
pidfile "tmp/pids/puma.pid"