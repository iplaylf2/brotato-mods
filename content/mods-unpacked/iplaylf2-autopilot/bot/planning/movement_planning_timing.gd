extends Reference

# Shared timing contract for rolling movement decisions. The local predictor
# owns [0, LOCAL_FORECAST_MAX_SECONDS]; navigation may only contribute terminal
# value beyond that interval. Only CONTROL_INTERVAL_SECONDS is committed.

const CONTROL_INTERVAL_SECONDS := 0.1
const LOCAL_FORECAST_MIN_SECONDS := 0.18
const LOCAL_FORECAST_DEFAULT_SECONDS := 0.45
const LOCAL_FORECAST_MAX_SECONDS := 0.7
const NAVIGATION_FORECAST_MAX_SECONDS := 1.2
