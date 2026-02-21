import React, { useEffect, useState } from 'react';
import './WeatherDashboard.css';

const REFRESH_INTERVAL_MS = 10 * 60 * 1000;
const FORECAST_SLOT_COUNT = 6;
const DEFAULT_ICON_CODE = '01d';

function getLocalDateKey(unixSeconds, offsetSeconds) {
  return new Date((unixSeconds + offsetSeconds) * 1000).toISOString().slice(0, 10);
}

function formatLocalTime(unixSeconds, offsetSeconds) {
  return new Date((unixSeconds + offsetSeconds) * 1000).toLocaleTimeString([], {
    hour: 'numeric',
    minute: '2-digit',
    timeZone: 'UTC',
  });
}

export default function WeatherDashboard() {
  const [currentWeather, setCurrentWeather] = useState(null);
  const [forecast, setForecast] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const city = process.env.REACT_APP_CITY;
  const apiKey = process.env.REACT_APP_OPENWEATHER_API_KEY;

  useEffect(() => {
    let ignoreResult = false;

    async function fetchWeather() {
      try {
        const timestamp = Date.now();
        const currentRes = await fetch(
          `https://api.openweathermap.org/data/2.5/weather?q=${city}&units=imperial&appid=${apiKey}&t=${timestamp}`
        );
        const forecastRes = await fetch(
          `https://api.openweathermap.org/data/2.5/forecast?q=${city}&units=imperial&appid=${apiKey}`
        );

        if (!currentRes.ok || !forecastRes.ok) {
          throw new Error('Error fetching weather data');
        }

        const currentData = await currentRes.json();
        const forecastData = await forecastRes.json();

        if (ignoreResult) {
          return;
        }

        setCurrentWeather(currentData);
        setForecast(forecastData.list);
        setError(null);
        setLoading(false);
      } catch (err) {
        if (ignoreResult) {
          return;
        }
        setError(err.message);
        setLoading(false);
      }
    }

    fetchWeather();
    const intervalId = setInterval(fetchWeather, REFRESH_INTERVAL_MS);

    return () => {
      ignoreResult = true;
      clearInterval(intervalId);
    };
  }, [apiKey, city]);

  if (loading) {
    return <div className="weather-dashboard--state weather-dashboard--loading">Loading...</div>;
  }

  if (error) {
    return <div className="weather-dashboard--state weather-dashboard--error">{error}</div>;
  }

  const temperature = Math.round(currentWeather.main.temp);
  const localOffset = currentWeather.timezone || 0;
  const iconCode = currentWeather.weather?.[0]?.icon || DEFAULT_ICON_CODE;
  const iconUrl = `https://openweathermap.org/img/wn/${iconCode}@4x.png`;

  const todayLocalDate = getLocalDateKey(currentWeather.dt, localOffset);
  const todaysForecast = forecast.filter((item) => getLocalDateKey(item.dt, localOffset) === todayLocalDate);

  const dailyHigh = todaysForecast.length > 0
    ? Math.round(Math.max(...todaysForecast.map((item) => item.main.temp_max)))
    : Math.round(currentWeather.main.temp_max);
  const dailyLow = todaysForecast.length > 0
    ? Math.round(Math.min(...todaysForecast.map((item) => item.main.temp_min)))
    : Math.round(currentWeather.main.temp_min);

  const forecastItems = forecast.slice(0, FORECAST_SLOT_COUNT);

  return (
    <div className="weather-dashboard">
      <div className="weather-dashboard__content">
        <div className="weather-dashboard__summary">
          <section className="weather-dashboard__summary-panel weather-dashboard__summary-panel--left">
            <div className="weather-dashboard__temperature">{temperature}°F</div>
          </section>
          <section className="weather-dashboard__summary-panel weather-dashboard__summary-panel--center">
            <img src={iconUrl} alt="Current weather icon" className="weather-dashboard__current-icon" />
          </section>
          <section className="weather-dashboard__summary-panel weather-dashboard__summary-panel--right">
            <div className="weather-dashboard__extremes">
              <div className="weather-dashboard__extreme-row">
                <span className="weather-dashboard__extreme-label">H</span> {dailyHigh}°
              </div>
              <div className="weather-dashboard__extreme-divider" />
              <div className="weather-dashboard__extreme-row">
                <span className="weather-dashboard__extreme-label">L</span> {dailyLow}°
              </div>
            </div>
          </section>
        </div>

        <div className="weather-dashboard__forecast">
          {forecastItems.map((hour) => {
            const hourIconCode = hour.weather?.[0]?.icon || DEFAULT_ICON_CODE;
            const hourIconUrl = `https://openweathermap.org/img/wn/${hourIconCode}@2x.png`;
            const hourDisplay = formatLocalTime(hour.dt, localOffset);
            const pop = Math.round((hour.pop || 0) * 100);

            return (
              <article key={hour.dt} className="weather-dashboard__forecast-card">
                <div className="weather-dashboard__forecast-time">{hourDisplay}</div>
                <img
                  src={hourIconUrl}
                  alt={`${hourDisplay} weather icon`}
                  className="weather-dashboard__forecast-icon"
                />
                <div className="weather-dashboard__forecast-pop">{pop}%</div>
              </article>
            );
          })}
        </div>
      </div>
    </div>
  );
}
