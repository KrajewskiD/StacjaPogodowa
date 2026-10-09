class Astronomy
  def self.call(settings, now: Time.current)
    age = ((now.to_f - Time.utc(2000, 1, 6, 18, 14).to_f) / 86400) % 29.530588853
    phases = ["Nów", "Przybywający sierp", "Pierwsza kwadra", "Przybywający garb", "Pełnia", "Ubywający garb", "Ostatnia kwadra", "Ubywający sierp"]
    result = { moon_phase: phases[(age / 29.530588853 * 8).round % 8], approximate: true,
               configured: !settings.latitude.nil? && !settings.longitude.nil? }
    return result unless result[:configured]
    date = now.in_time_zone.to_date
    days = [date, date + 1].map do |day|
      sunrise = sun_event(day, settings.latitude, settings.longitude, true)
      sunset = sun_event(day, settings.latitude, settings.longitude, false)
      { date: day.iso8601, sunrise: sunrise, sunset: sunset,
        daylight_minutes: sunrise && sunset ? ((sunset - sunrise) / 60.0).round : nil,
        polar: sunrise.nil? || sunset.nil? }
    end
    rise, set = days.first.values_at(:sunrise, :sunset)
    next_rise = rise && rise > now ? rise : days.last[:sunrise]
    next_set = set && set > now ? set : days.last[:sunset]
    result.merge(sunrise: rise, sunset: set,
                 daylight_hours: rise && set ? ((set - rise) / 3600.0).round(2) : nil,
                 next_sunrise: next_rise, next_sunset: next_set,
                 polar: rise.nil? || set.nil?, days: days)
  end

  # Przybliżony algorytm USNO: zenit 90,833° uwzględnia refrakcję.
  def self.sun_event(date, latitude, longitude, sunrise)
    rad = Math::PI / 180
    lng_hour = longitude / 15.0
    t = date.yday + ((sunrise ? 6 : 18) - lng_hour) / 24.0
    m = 0.9856 * t - 3.289
    l = (m + 1.916 * Math.sin(m * rad) + 0.020 * Math.sin(2 * m * rad) + 282.634) % 360
    ra = (Math.atan(0.91764 * Math.tan(l * rad)) / rad) % 360
    ra = (ra + (l / 90).floor * 90 - (ra / 90).floor * 90) / 15
    sin_dec = 0.39782 * Math.sin(l * rad)
    cos_dec = Math.cos(Math.asin(sin_dec))
    denominator = cos_dec * Math.cos(latitude * rad)
    return nil if denominator.abs < 1e-10
    cos_h = (Math.cos(90.833 * rad) - sin_dec * Math.sin(latitude * rad)) / denominator
    return nil unless (-1..1).cover?(cos_h)
    h = Math.acos(cos_h) / rad
    h = 360 - h if sunrise
    utc_hours = (h / 15 + ra - 0.06571 * t - 6.622 - lng_hour) % 24
    event = (Time.utc(date.year, date.month, date.day) + utc_hours * 3600).in_time_zone
    # Datę wyświetlamy w skonfigurowanej strefie Europe/Warsaw.
    event += (date - event.to_date).to_i.days
    event
  end
end
