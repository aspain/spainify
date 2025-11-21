import React, { useEffect, useState } from 'react';

export default function WeatherDashboard() {
  const [currentWeather, setCurrentWeather] = useState(null);
  const [forecast, setForecast] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);

  const city = process.env.REACT_APP_CITY;
  const apiKey = process.env.REACT_APP_OPENWEATHER_API_KEY;

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
      <div className="w-[1280px] h-[400px] flex items-center justify-center bg-gray-800 text-white text-3xl">
        Loading...
      </div>
    );
  }

  if (error) {
    return (
      <div className="w-[1280px] h-[400px] flex items-center justify-center bg-red-700 text-white text-3xl">
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
    <div className="w-[1280px] h-[400px] bg-gradient-to-r from-blue-700 to-indigo-800 text-white flex flex-col p-6 justify-center">
      <div className="flex flex-row w-full mb-1">
        <div className="w-1/3 flex justify-center items-center">
          <div className="text-8xl font-extrabold">
            {temperature}°F
          </div>
        </div>
        <div className="w-1/3 flex justify-center items-center">
          <img src={iconUrl} alt="weather icon" className="w-72 h-72" />
        </div>
        <div className="w-1/3 flex flex-col justify-center items-center">
          <div className="inline-block text-center">
            <div className="text-6xl">
              <span className="font-bold">H</span> {dailyHigh}°
            </div>
            <div className="my-1 h-[2px] bg-white w-full" />
            <div className="text-6xl">
              <span className="font-bold">L</span> {dailyLow}°
            </div>
          </div>
        </div>
      </div>
      <div className="flex flex-col -mt-12 pb-16">
        <div className="flex flex-row gap-8 justify-evenly items-center w-full">
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
                className="flex flex-col items-center justify-center bg-white/20 rounded-2xl p-4 w-48"
              >
                <div className="text-3xl font-bold -mb-2">{hourDisplay}</div>
                <img
                  src={hourIconUrl}
                  alt="forecast icon"
                  className="w-25 h-25 -mb-2"
                />
                <div className="text-4xl font-semibold">{pop}%</div>
              </div>
            );
          })}
        </div>
      </div>
    </div>
  );
}
