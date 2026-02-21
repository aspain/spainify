import React, { useEffect, useState } from 'react';

export default function WeatherDashboard() {
  const [currentWeather, setCurrentWeather] = useState(null);
  const [forecast, setForecast] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const city = process.env.REACT_APP_CITY;
  const apiKey = process.env.REACT_APP_OPENWEATHER_API_KEY;
  const dashboardBaseClass =
    "w-screen h-screen overflow-hidden text-white";

  useEffect(() => {
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

        setCurrentWeather(currentData);
        // Save full forecast list for later processing
        setForecast(forecastData.list);
        setLoading(false);
      } catch (err) {
        setError(err.message);
        setLoading(false);
      }
    }
    fetchWeather();
    const intervalId = setInterval(fetchWeather, 600000);
    return () => clearInterval(intervalId);
  }, [city, apiKey]);

  if (loading) {
    return (
      <div className={`${dashboardBaseClass} flex items-center justify-center bg-gray-800 text-[clamp(1.5rem,4vw,3rem)]`}>
        Loading...
      </div>
    );
  }

  if (error) {
    return (
      <div className={`${dashboardBaseClass} flex items-center justify-center bg-red-700 text-[clamp(1.5rem,4vw,3rem)]`}>
        {error}
      </div>
    );
  }

  // Current temperature and icon from current weather data
  const temperature = Math.round(currentWeather.main.temp);
  const iconCode = currentWeather.weather?.[0]?.icon || "01d";
  const iconUrl = `https://openweathermap.org/img/wn/${iconCode}@4x.png`;

  // Compute the day's high and low using forecast data.
  // Use the timezone offset (in seconds) from the current weather data
  const localOffset = currentWeather.timezone;
  // Get today's local date string (YYYY-MM-DD) by applying the offset to the current weather timestamp.
  const todayLocalDate = new Date((currentWeather.dt + localOffset) * 1000)
    .toISOString()
    .slice(0, 10);

  // Filter forecast items that match today's local date.
  const todaysForecast = forecast.filter(item => {
    const itemLocalDate = new Date((item.dt + localOffset) * 1000)
      .toISOString()
      .slice(0, 10);
    return itemLocalDate === todayLocalDate;
  });

  // If forecast items for today exist, compute the high and low.
  // Otherwise, fall back to the values from the current weather endpoint.
  const dailyHigh = todaysForecast.length > 0
    ? Math.round(Math.max(...todaysForecast.map(item => item.main.temp_max)))
    : Math.round(currentWeather.main.temp_max);
  const dailyLow = todaysForecast.length > 0
    ? Math.round(Math.min(...todaysForecast.map(item => item.main.temp_min)))
    : Math.round(currentWeather.main.temp_min);

  // For the forecast row below, you can still show the next six time steps.
  const forecastItems = forecast.slice(0, 6);

  return (
    <div className={`${dashboardBaseClass} flex flex-col bg-gradient-to-r from-blue-700 to-indigo-800 px-[clamp(1rem,2.2vw,2.5rem)] py-[clamp(0.75rem,2vh,2rem)]`}>
      <div className="grid min-h-0 flex-1 grid-cols-1 grid-rows-3 items-center gap-[clamp(0.5rem,1.4vw,2rem)] md:grid-cols-3 md:grid-rows-1">
        <div className="flex items-center justify-center">
          <div className="text-[clamp(2.75rem,9vw,10rem)] font-extrabold leading-none">
            {temperature}°F
          </div>
        </div>
        <div className="flex items-center justify-center">
          <img
            src={iconUrl}
            alt="weather icon"
            className="h-[clamp(4rem,20vw,18rem)] w-[clamp(4rem,20vw,18rem)] object-contain"
          />
        </div>
        <div className="flex items-center justify-center">
          <div className="inline-flex flex-col items-center text-center">
            <div className="text-[clamp(2rem,5vw,5rem)] leading-none">
              <span className="font-bold">H</span> {dailyHigh}°
            </div>
            <div className="my-[clamp(0.25rem,1vh,0.75rem)] h-[max(2px,0.25vh)] w-full bg-white/80" />
            <div className="text-[clamp(2rem,5vw,5rem)] leading-none">
              <span className="font-bold">L</span> {dailyLow}°
            </div>
          </div>
        </div>
      </div>
      <div className="mt-[clamp(0.5rem,1.8vh,1.5rem)] grid grid-cols-3 gap-[clamp(0.4rem,1vw,1rem)] sm:grid-cols-6">
        {forecastItems.map((hour, index) => {
          const hourIconCode = hour.weather?.[0]?.icon || "01d";
          const hourIconUrl = `https://openweathermap.org/img/wn/${hourIconCode}@2x.png`;
          const dateObj = new Date(hour.dt * 1000);
          const hourDisplay = dateObj.toLocaleTimeString([], {
            hour: 'numeric',
            minute: '2-digit',
          });
          const pop = Math.round((hour.pop || 0) * 100);
          return (
            <div
              key={index}
              className="flex min-w-0 flex-col items-center justify-center rounded-[clamp(0.5rem,1.2vw,1rem)] bg-white/20 px-[clamp(0.2rem,0.8vw,0.75rem)] py-[clamp(0.3rem,1vh,0.75rem)]"
            >
              <div className="text-[clamp(0.9rem,1.9vw,2rem)] font-bold leading-none">{hourDisplay}</div>
              <img
                src={hourIconUrl}
                alt="forecast icon"
                className="h-[clamp(2.5rem,6vw,6rem)] w-[clamp(2.5rem,6vw,6rem)] object-contain"
              />
              <div className="text-[clamp(1rem,2.6vw,2.5rem)] font-semibold leading-none">{pop}%</div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
