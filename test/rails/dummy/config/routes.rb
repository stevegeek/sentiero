# frozen_string_literal: true

SentieroTest::Application.routes.draw do
  mount Sentiero::Web::ErrorsApp.new, at: "/sentiero/errors"
  mount Sentiero::Web::TrackApp.new, at: "/sentiero/track"
  mount Sentiero::Web::EventsApp.new, at: "/sentiero/events"
  mount Sentiero::Web::DashboardApp.new, at: "/sentiero"
  get "unmasking", to: "pages#unmasking"
  root "pages#home"
end
