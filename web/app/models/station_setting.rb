class StationSetting < ApplicationRecord
  attribute :temperature_low_clear, :float, default: 1.0
  attribute :temperature_high_clear, :float, default: 29.0
  attribute :gust_clear, :float, default: 12.0
  attribute :uv_clear, :float, default: 5.0
  attribute :cold_confirm_seconds, :integer, default: 120
  attribute :hot_confirm_seconds, :integer, default: 300
  attribute :gust_clear_seconds, :integer, default: 600
  attribute :uv_confirm_seconds, :integer, default: 120
  attribute :uv_clear_seconds, :integer, default: 300
  attribute :confirmation_gap_seconds, :integer, default: 60
  attribute :battery_confirm_seconds, :integer, default: 30
  attribute :sensors, :json, default: []
  attribute :devices, :json, default: []

  validates :latitude, numericality: { in: -90..90 }, allow_nil: true
  validates :longitude, numericality: { in: -180..180 }, allow_nil: true
  validates :temperature_low, :temperature_high, numericality: { in: -80..80 }
  validates :gust_high, numericality: { greater_than: 0, less_than_or_equal_to: 100 }
  validates :uv_high, numericality: { greater_than: 0, less_than_or_equal_to: 20 }
  validates :missing_seconds, numericality: { only_integer: true, in: 60..3600 }
  validates :temperature_low_clear, :temperature_high_clear, numericality: { in: -80..80 }
  validates :gust_clear, numericality: { in: 0..100 }
  validates :uv_clear, numericality: { in: 0..20 }
  validates :cold_confirm_seconds, :hot_confirm_seconds, :gust_clear_seconds,
    :uv_confirm_seconds, :uv_clear_seconds, :battery_confirm_seconds,
    numericality: { only_integer: true, in: 0..3600 }
  validates :confirmation_gap_seconds, numericality: { only_integer: true, in: 15..180 }
  validate do
    errors.add(:base, "Podaj obie współrzędne albo pozostaw obie puste") if latitude.nil? != longitude.nil?
    if temperature_low && temperature_high && temperature_low >= temperature_high
      errors.add(:base, "Próg dolny temperatury musi być niższy od górnego")
    end
    if temperature_low && temperature_low_clear && temperature_high && temperature_high_clear &&
        !(temperature_low < temperature_low_clear && temperature_low_clear < temperature_high_clear && temperature_high_clear < temperature_high)
      errors.add(:base, "Progi temperatury muszą zachowywać kolejność: dolny, wyłączenie zimna, wyłączenie upału, górny")
    end
    errors.add(:gust_clear, "musi być niższy od progu włączenia") if gust_clear && gust_high && gust_clear >= gust_high
    errors.add(:uv_clear, "musi być niższy od progu włączenia") if uv_clear && uv_high && uv_clear >= uv_high
    if confirmation_gap_seconds && missing_seconds && confirmation_gap_seconds > missing_seconds
      errors.add(:confirmation_gap_seconds, "nie może przekraczać czasu braku danych")
    end
    unless sensors.is_a?(Array) && sensors.all? { |id| id.is_a?(String) && id.match?(/\A[0-9A-F]{8}\z/i) }
      errors.add(:sensors, "musi być listą 8-znakowych identyfikatorów hex")
    end
    unless devices.is_a?(Array) && devices.all? { |id| id.is_a?(String) && id.match?(/\A[0-9a-fA-F]{1,16}\z/) }
      errors.add(:devices, "musi być listą identyfikatorów urządzeń (1–16 znaków hex)")
    end
  end

  def self.current
    settings = new(configured)
    settings.validate!
    settings.readonly!
    settings
  end

  # Odczyt i parsowanie YAML tylko raz na proces; model pozostaje nowym,
  # zwalidowanym egzemplarzem przy każdym wywołaniu (bez współdzielenia stanu).
  def self.configured
    @configured ||= Rails.application.config_for(:station).to_h.dup
  end

  def self.reset!
    @configured = nil
  end
end