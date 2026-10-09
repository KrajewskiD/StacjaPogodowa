Rails.application.routes.draw do
  root "weather#index"
  get "/api/weather", to: "weather#show"
  post "/api/measurements", to: "measurements#create"
  get "/export.csv", to: "weather#export", as: :export
  get "/history", to: "weather#index"
  get "/alerts", to: "weather#index"
  get "/up", to: "rails/health#show"
end
