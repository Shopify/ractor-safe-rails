# Ractor-safe Rails

This repo contains a small Rails application for testing Ractor support in Rails. The app will grow as more functionality becomes Ractor-safe.

`bin/ractor-test` boots the application, makes it Ractor-shareable and runs each request in a non-main Ractor.
