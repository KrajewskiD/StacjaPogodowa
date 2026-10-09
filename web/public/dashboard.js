(() => {
  const byId = id => document.getElementById(id);
  if (!byId('connection')) return;
  const formatter = new Intl.NumberFormat('pl-PL', { maximumFractionDigits: 2 });
  const number = value => typeof value === 'number' && Number.isFinite(value) ? formatter.format(value) : '—';
  const time = value => new Date(value).toLocaleTimeString('pl-PL', { timeZone: 'Europe/Warsaw', hour: '2-digit', minute: '2-digit', second: '2-digit' });
  let busy = false;
  let latestData;
  let selectedDate = '', requestVersion = 0, serverOffset = 0;
  const statusText = s => ({complete:'Pełne dane', partial:'Niepełne dane', no_data:'Brak danych', insufficient:'Za mało pomiarów do średniej', future:'Jeszcze się nie rozpoczął'}[s] || 'Brak danych');
  const help = {
    incompleteRain: ['Niepełne dane — opady', [
      'Nie cały wybrany okres jest objęty pomiarami. Przyczyną może być rozpoczęcie rejestracji w trakcie okresu, przerwa w odbiorze lub reset licznika czujnika.',
      'Podana suma obejmuje wyłącznie przyrosty możliwe do przypisania do tego okresu. Rzeczywista suma opadów może być większa. Wartość 0 mm przy niepełnych danych nie potwierdza, że przez cały okres nie padało.',
      'Niektóre przyrosty mogą być odzyskane z licznika po przerwie, ale czasu ich wystąpienia nie zawsze da się ustalić. Natężenie opadów nie jest obliczane, jeśli wymagane dane są niepełne.',
      'Nowe pomiary poprawiają pokrycie, lecz nie odtwarzają automatycznie brakującej historii. Po wyczyszczeniu bazy wcześniejsza część dnia, tygodnia lub miesiąca pozostaje niepełna.'
    ]],
    incompleteStats: ['Niepełne dane — statystyki', [
      'Pomiary nie obejmują całego analizowanego przedziału. Procent pokrycia wskazuje, jaką część tego czasu reprezentują dostępne dane. Dla dzisiaj oceniany jest tylko czas, który już upłynął.',
      'Średnia jest obliczana wyłącznie z dostępnych odcinków pomiarowych. Przerwy ponad 2 minuty są pomijane i nie są zastępowane zerami. Wynik może nie odzwierciedlać warunków w całym okresie.',
      'Minimum i maksimum dotyczą dostępnych danych. Podczas przerwy mogły wystąpić niższe lub wyższe wartości, których nie zarejestrowano.',
      'Po rozpoczęciu rejestracji lub wyczyszczeniu bazy wcześniejsze godziny pozostają bez danych. Kolejne odczyty nie uzupełniają tych braków wstecz.'
    ]],
    smoothing: ['Ostatnie 5 minut', [
      'Wskazania są przeliczane z ruchomego okna ostatnich 5 minut przy odświeżaniu panelu. Wszystkie odebrane pomiary są nadal zapisywane.',
      'Temperatura, wilgotność, UV i światło: mediana. Punkt rosy i temperatura odczuwalna: mediana wyników obliczonych dla poszczególnych pomiarów.',
      'Wiatr: średnia ważona czasem. Poryw: maksimum z 5 minut. Kierunek: średnia kołowa ważona prędkością i czasem; przy ciszy lub przeciwnych kierunkach może być niedostępny.',
      'Przerwy ponad minutę nie są uwzględniane w średniej wiatru ani pokryciu. Wynik jest wstępny do zebrania co najmniej 10 pomiarów i 4 minut pokrycia okna. Brak danych nie jest zastępowany zerem.',
      'Opady pozostają sumą przyrostów licznika. Alerty i historia korzystają z pomiarów źródłowych, bez wygładzania.'
    ]],
    rain: ['Opady — sposób obliczania', [
      'Sumy opadów pochodzą z przyrostów licznika czujnika.',
      'Niepełny okres oznacza dane od początku rejestracji albo okres z lukami lub resetem licznika. Wartość obejmuje tylko przyrosty możliwe do przypisania do tego okresu.',
      'Szacowane natężenie dotyczy ostatnich 10 minut. Przy niepełnych danych nie jest obliczane.'
    ]],
    stats: ['Statystyki i średnie', [
      'Średnie są ważone czasem między pomiarami (metoda trapezów). Przerwy ponad 2 minuty są pomijane.',
      'Pokrycie określa czas reprezentowany przez pomiary. Dla dzisiejszego dnia uwzględniany jest tylko czas do chwili obliczenia. Statystyki są aktualizowane co 30 sekund.',
      'Noc łączna obejmuje okresy przed wschodem i po zachodzie słońca tej samej doby.'
    ]],
    feels: ['Wartości obliczone', [
      'Temperatura odczuwalna korzysta z wind chill w chłodzie i przy wietrze, heat index przy upale, a poza tym z apparent temperature.',
      'Brak wymaganych pomiarów oznacza brak wyniku.',
      'Wartość historyczna jest średnią ważoną wyników obliczonych dla poszczególnych pomiarów.'
    ]],
    astronomy: ['Astronomia', [
      'Wschód i zachód są obliczane dla wybranej daty i współrzędnych stacji ustawionych na serwerze.',
      'Godziny są podawane w strefie Europe/Warsaw, z uwzględnieniem zmiany czasu.',
      'Obliczenia astronomiczne i faza Księżyca są przybliżone.'
    ]]
  };
  const dialog = byId('help-dialog');
  const dateDialog = byId('date-dialog');
  byId('date-close').onclick = () => dateDialog.close();
  byId('date-form').addEventListener('submit', event => {
    event.preventDefault();
    if (!byId('date-form').reportValidity()) return;
    selectedDate = byId('history-date').value;
    requestVersion++;
    dateDialog.close();
    refresh();
  });
  dateDialog.addEventListener('click', event => {
    const r = dateDialog.getBoundingClientRect();
    if (event.target === dateDialog && (event.clientX < r.left || event.clientX > r.right || event.clientY < r.top || event.clientY > r.bottom)) dateDialog.close();
  });
  document.addEventListener('click', event => {
    const button = event.target.closest('[data-help]');
    if (!button) return;
    const [title, paragraphs] = help[button.dataset.help];
    byId('help-title').textContent = title;
    byId('help-content').replaceChildren(...paragraphs.map(text => element('p', text)));
    if (button.dataset.help === 'rain') {
      if (latestData?.mode === 'live') byId('help-content').append(element('p', `Licznik czujnika, narastająco od resetu: ${number(latestData.latest?.rain_total_mm)} mm.`));
      byId('help-content').append(element('h3', 'Szczegóły wyświetlanych okresów'));
      const list = element('ul');
      Object.entries(latestData?.statistics?.rain || {}).forEach(([key, value]) => {
      const labels = {hour:'60 min',today:'Dzisiaj',day:'24 h',week:'Tydzień',month:'Miesiąc',ten_minutes:'10 min',selected:'Wybrany dzień'};
        list.append(element('li', `${labels[key] || key}: resety/zmiany ${value.resets || 0}, luki ${value.gaps || 0}.`));
      });
      byId('help-content').append(list);
    }
    dialog.showModal();
  });
  byId('help-close').onclick = () => dialog.close();
  dialog.addEventListener('click', e => { if (e.target === dialog) { const r = dialog.getBoundingClientRect(); if(e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) dialog.close(); } });
  const view = location.pathname === '/alerts' ? 'alerts' : location.pathname === '/history' ? 'history' : 'live';
  document.body.classList.add(`view-${view}`);
  byId('csv-export').replaceChildren(document.createTextNode('CSV '), icon('download'));
  document.querySelectorAll('.page-live, .page-history, .page-alerts').forEach(node => {
    node.hidden = !node.classList.contains(`page-${view}`);
  });
  document.querySelectorAll('.app-nav a').forEach(node => node.classList.toggle('active', node.getAttribute('href') === location.pathname));
  const titles = { live: 'Pogoda na żywo', history: 'Historia i wykresy', alerts: 'Alerty pogodowe' };
  document.querySelector('h1').textContent = `${titles[view]}.`;
  byId('range').addEventListener('change', () => { selectedDate = ''; requestVersion++; refresh(); });
  const dayOption = element('option', 'Wybrany dzień'); dayOption.value = 'day'; dayOption.disabled = true; byId('range').append(dayOption);
  byId('chart-metric').addEventListener('change', () => { if (latestData) drawChart(latestData.chart || latestData.history); });

  byId('today').textContent = new Date().toLocaleDateString('pl-PL', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });

  function svgNode(tag, attrs) {
    const element = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [key, value] of Object.entries(attrs)) element.setAttribute(key, value);
    return element;
  }

  function icon(name) {
    const svg = svgNode('svg', {class:'line-icon', 'aria-hidden':'true', focusable:'false'});
    svg.append(svgNode('use', {href:`/icons.svg#${name}`}));
    return svg;
  }

  function drawChart(history) {
    const svg = byId('chart');
    svg.replaceChildren();
    const metric = byId('chart-metric').value;
    const label = byId('chart-metric').selectedOptions[0].textContent;
    byId('chart-title').textContent = label;
    byId('chart-label').textContent = label;
    svg.setAttribute('aria-label', `${label} — wybrany okres`);
    let missing = false;
    const points = history.flatMap(row => {
      if (typeof row[metric] !== 'number') { missing = true; return []; }
      const point = { ...row, break_before: row.break_before || missing };
      missing = false; return [point];
    });
    svg.toggleAttribute('hidden', !points.length);
    byId('chart-empty').hidden = points.length > 0;
    byId('chart-range').textContent = '';
    byId('chart-start').textContent = points.length ? time(points[0].received_at) : '—';
    byId('chart-end').textContent = points.length ? time(points.at(-1).received_at) : '—';
    if (!points.length) return;
    const values = points.map(row => row[metric]);
    const min = Math.min(...values), max = Math.max(...values);
    const lo = min - 0.5, hi = max + 0.5;
    const start = Date.parse(points[0].received_at), end = Date.parse(points.at(-1).received_at);
    const x = row => 50 + (Date.parse(row.received_at) - start) / Math.max(end - start, 1) * 835;
    const y = row => 175 - (row[metric] - lo) / (hi - lo) * 155;
    byId('chart-range').textContent = `MIN ${number(min)} · MAX ${number(max)}`;
    for (let i = 0; i < 4; i++) {
      const height = 20 + i * 155 / 3;
      svg.append(svgNode('line', { x1: 50, x2: 890, y1: height, y2: height, stroke: 'var(--line)', 'stroke-dasharray': '4 5' }));
      const label = svgNode('text', { x: 0, y: height + 4, fill: 'var(--muted)', 'font-size': 11 });
      label.textContent = number(hi - i * (hi - lo) / 3);
      svg.append(label);
    }
    const segments = [];
    points.forEach(point => {
      if (!segments.length || point.break_before) segments.push([]);
      segments.at(-1).push(point);
    });
    segments.forEach(segment => {
      const path = segment.map((row, i) => `${i ? 'L' : 'M'}${x(row)},${y(row)}`).join(' ');
      svg.append(svgNode('path', { d: `${path} L${x(segment.at(-1))},185 L${x(segment[0])},185 Z`, fill: 'var(--chart-fill)' }));
      svg.append(svgNode('path', { d: path, fill: 'none', stroke: 'var(--chart-line)', 'stroke-width': 2.5, 'stroke-linejoin': 'round' }));
    });
    svg.append(svgNode('circle', { cx: x(points.at(-1)), cy: y(points.at(-1)), r: 4, fill: 'var(--chart-line)', stroke: 'var(--surface)', 'stroke-width': 2 }));
  }

  function render(data) {
    latestData = data;
    serverOffset = Date.parse(data.server_time) - Date.now();
    const historical = data.mode === 'historical';
    const row = data.display || data.latest || {};
    byId('day-picker').replaceChildren(...(data.available_dates || []).slice(0, view === 'history' ? 8 : 3).map((date, index) => {
      if (view === 'history' && [4, 5, 6].includes(index)) return null;
      const button = element('button', index === 0 ? 'Dzisiaj' : index === 1 ? 'Wczoraj' : index === 2 ? 'Przedwczoraj' : `${index} dni temu`);
      button.title = date; button.setAttribute('aria-pressed', String(date === data.selected_date && (view !== 'history' || data.period_mode === 'day')));
      button.disabled = date < data.date_bounds.min;
      button.onclick = () => { selectedDate = index === 0 && view !== 'history' ? '' : date; requestVersion++; refresh(); };
      return button;
    }).filter(Boolean));
    const calendarButton = element('button', '…');
    calendarButton.setAttribute('aria-label', 'Wybierz datę z całej historii');
    calendarButton.setAttribute('aria-haspopup', 'dialog');
    calendarButton.setAttribute('aria-pressed', String(data.period_mode === 'day' && ![0, 1, 2, 3, 7].some(index => data.available_dates[index] === data.selected_date)));
    calendarButton.onclick = () => {
      const input = byId('history-date');
      input.min = latestData.date_bounds.min; input.max = latestData.date_bounds.max;
      input.value = latestData.selected_date;
      byId('date-range').textContent = `Historia od ${input.min} do ${input.max}. Dni bez pomiarów pokażą „Brak danych”.`;
      dateDialog.showModal();
      input.focus();
    };
    if (view === 'history') {
      byId('day-picker').append(calendarButton);
      if (data.period_mode === 'day') byId('range').value = 'day';
      byId('today').textContent = data.period_mode === 'day' ? `Pomiary z dnia ${data.selected_date}` : `Ostatnie ${data.range_hours} godz. — do chwili obecnej`;
    }
    if (view === 'live') {
      document.querySelector('h1').textContent = historical ? 'Podsumowanie dnia.' : 'Pogoda na żywo.';
      byId('today').textContent = new Date(`${data.selected_date}T12:00:00Z`).toLocaleDateString('pl-PL', {timeZone:'Europe/Warsaw', weekday:'long', day:'numeric', month:'long', year:'numeric'});
    }
    const smoothStatus = {ready:'', preliminary:'', no_data:' · Brak pomiarów w oknie'};
    byId('day-status').textContent = historical ? `Średnie ważone z wybranej doby; poryw i UV — maksimum. ${statusText(data.day?.status)}.` : `Ostatnie 5 min${smoothStatus[data.smoothing?.status] || ''}. Opady: suma dnia.`;
    byId('smoothing-help').hidden = historical;
    byId('temperature-summary').textContent = historical ? 'Średnia ważona temperatury' : '';
    byId('temperature-summary').hidden = !historical;
    byId('day-rain').textContent = number(data.day?.rain?.mm);
    byId('day-rain-status').replaceChildren(statusBadge(data.day?.rain?.status, 'incompleteRain'));
    byId('uv-title').textContent = historical ? 'Maksymalny indeks UV' : 'Indeks UV';
    byId('light-description').textContent = historical ? 'Średnia ważona z dnia' : 'Mediana · 5 min';
    document.querySelector('.metric-card p').textContent = historical ? 'Średnia ważona wilgotności' : 'Mediana · 5 min';
    document.querySelectorAll('.metric-card h2')[1].textContent = historical ? 'Średni wiatr' : 'Wiatr';
    byId('stats-title').textContent = `${historical ? data.selected_date : 'Dzisiaj'}: minima, maksima i średnie`;
    byId('temperature-periods').replaceChildren();
    for (const [key, label] of Object.entries({full:'Cała doba',before_sunrise:'Noc: 00:00 → wschód',daylight:'Dzień: wschód → zachód',after_sunset:'Noc: zachód → 00:00',night:'Noc łącznie'})) {
      const s = data.day?.temperature_periods?.[key];
      if (!s) continue;
      const card = element('article');
      card.dataset.period = key;
      card.append(element('h3',label), element('strong',`${number(s.mean)} °C`), statusBadge(s.status, 'incompleteStats'));
      card.append(element('p', `Pokrycie: ${number(s.coverage_pct)}%`));
      if (key !== 'full') card.append(element('p', (s.periods || []).map(p => `${time(p.from).slice(0,5)}–${time(p.to).slice(0,5)}`).join(' + ')));
      byId('temperature-periods').append(card);
    }
    if (!data.day?.temperature_periods?.daylight) byId('temperature-periods').append(element('p', 'Podział dnia i nocy niedostępny — brak wyliczonego wschodu lub zachodu.'));
    document.querySelectorAll('[data-value]').forEach(node => { node.textContent = number(row[node.dataset.value]); });
    const badge = byId('connection');
    badge.classList.toggle('stale', data.stale);
    badge.replaceChildren(document.createElement('span'), document.createTextNode(historical ? 'Dane historyczne' : data.stale ? 'Brak świeżych danych' : 'Odczyt na żywo'));
    byId('notice').hidden = !data.stale;
    byId('notice').textContent = data.latest ? `Od co najmniej ${number(data.missing_seconds / 60)} min nie otrzymano nowych pomiarów. Wskazania z okna 5 minut mogą być nieaktualne; po jego upływie widoczny jest brak danych.` : 'Oczekiwanie na pierwsze pomiary. Dane zostaną wyświetlone automatycznie.';
    byId('updated').textContent = historical ? data.selected_date : data.latest?.received_at ? `Odczyt o ${time(data.latest.received_at)}` : 'Oczekiwanie na dane';
    byId('total').textContent = `${number(data.total)} zapisanych pomiarów`;
    const body = byId('history');
    body.replaceChildren();
    for (const reading of data.history.slice(-8).reverse()) {
      const tr = document.createElement('tr');
      for (const value of [time(reading.received_at), `${number(reading.temperature_c)} °C`, `${number(reading.humidity_pct)} %`, `${number(reading.wind_avg_ms)} m/s`]) {
        const td = document.createElement('td'); td.textContent = value; tr.append(td);
      }
      body.append(tr);
    }
    if (!body.children.length) {
      const tr = document.createElement('tr'), td = document.createElement('td');
      td.colSpan = 4; td.textContent = 'Brak pomiarów z wybranego okresu.'; tr.append(td); body.append(tr);
    }
    drawChart(data.chart || data.history);
    renderFeatures(data);
  }

  function element(tag, text, className) {
    const node = document.createElement(tag);
    if (text !== undefined) node.textContent = text;
    if (className) node.className = className;
    return node;
  }

  function statusBadge(status, topic) {
    const node = element(status === 'partial' ? 'button' : 'span', statusText(status), 'data-status');
    if (status === 'partial') {
      node.type = 'button';
      node.dataset.help = topic;
      node.setAttribute('aria-haspopup', 'dialog');
      node.setAttribute('aria-label', `Niepełne dane — wyjaśnienie: ${topic === 'incompleteRain' ? 'opady' : 'statystyki'}`);
    }
    return node;
  }

  const timestamp = value => value ? new Date(value).toLocaleString('pl-PL', { timeZone: 'Europe/Warsaw' }) : '—';

  function renderFeatures(data) {
    const historical = data.mode === 'historical';
    const derived = data.derived || {}, row = data.display || data.latest || {};
    document.querySelectorAll('[data-derived]').forEach(node => { node.textContent = number(derived[node.dataset.derived]); });
    byId('feels-method').textContent = derived.feels_like_method || 'Poza zakresem obliczeń / brak danych';
    byId('wind-text').textContent = derived.calm ? 'Cisza — kierunek niemiarodajny' : derived.wind_direction || '—';
    const direction = row.wind_direction_deg;
    byId('compass-needle').style.transform = `rotate(${Number.isFinite(direction) ? direction : 0}deg)`;
    byId('compass-needle').style.opacity = derived.calm || !Number.isFinite(direction) ? '0.3' : '1';
    byId('uv-level').textContent = derived.uv_level || '—';
    byId('csv-export').href = data.period_mode === 'day' ? `/export.csv?date=${data.selected_date}` : `/export.csv?hours=${byId('range').value}`;
    const stats = data.statistics || {}, rain = stats.rain || {};
    byId('rain-summary').replaceChildren();
    for (const [key, name] of Object.entries(historical ? {selected:data.selected_date} : {hour:'Ostatnie 60 min', today:'Dzisiaj', day:'Ostatnie 24 h', week:'Ten tydzień', month:'Ten miesiąc'})) {
      const value = (key === 'today' ? data.day?.rain : rain[key]) || {};
      const card = element('div');
      card.append(element('h3', name), element('strong', `${number(value.mm)} mm`));
      if (value.mm == null || value.partial) card.append(statusBadge(value.mm == null ? 'no_data' : 'partial', 'incompleteRain'));
      byId('rain-summary').append(card);
    }
    byId('rain-rate').textContent = historical ? '' : `Szacowane natężenie z ostatnich 10 min: ${number(rain.ten_minutes?.rate_mmh)} mm/h`;
    const table = element('table'), head = element('tr');
    ['Pomiar', 'Minimum / czas', 'Maksimum / czas', 'Średnia', 'Pokrycie'].forEach(value => head.append(element('th', value)));
    const thead = element('thead'); thead.append(head); table.append(thead);
    const tbody = element('tbody');
    for (const [key, name] of Object.entries({temperature_c:'Temperatura °C', humidity_pct:'Wilgotność %', wind_gust_ms:'Poryw m/s', uv_index:'UV', light_klx:'Światło klx'})) {
      const s = stats.daily?.[key];
      const tr = element('tr');
      [name, s?.min_at ? `${number(s.min)} / ${time(s.min_at)}` : '—', s?.max_at ? `${number(s.max)} / ${time(s.max_at)}` : '—', number(s?.mean)].forEach(value => tr.append(element('td', value)));
      const coverage = element('td', `${number(s?.coverage_pct)}% `);
      coverage.append(statusBadge(s?.status, 'incompleteStats'));
      tr.append(coverage);
      tbody.append(tr);
    }
    table.append(tbody); byId('daily-stats').replaceChildren(table);
    byId('trends').replaceChildren();
    byId('trends').hidden = historical;
    for (const [period, name] of Object.entries({'1800':'30 min', '10800':'3 h'})) {
      const trend = stats.trends?.[period] || {};
      const signed = value => typeof value === 'number' ? `${value > 0 ? '+' : ''}${number(value)}` : '—';
      byId('trends').append(element('p', `Zmiana ${name}: temperatura ${signed(trend.temperature_c)} °C · wilgotność ${signed(trend.humidity_pct)} p.p.`));
    }
    const astro = data.astronomy || {};
    byId('astronomy').replaceChildren(element('p', `Księżyc: ${astro.moon_phase || '—'} (przybliżenie)`));
    if (!astro.configured) {
      byId('astronomy').append(element('p', 'Dane o wschodzie i zachodzie słońca są obecnie niedostępne.'));
    } else {
      const days = element('div', undefined, 'astronomy-days');
      const sunTime = value => value ? new Date(value).toLocaleTimeString('pl-PL', { timeZone: 'Europe/Warsaw', hour: '2-digit', minute: '2-digit' }) : '—';
      (astro.days || []).forEach((day, index) => {
        const card = element('article', undefined, 'astronomy-day');
        const date = new Date(`${day.date}T12:00:00Z`).toLocaleDateString('pl-PL', { timeZone: 'Europe/Warsaw', day: 'numeric', month: 'long', year: 'numeric' });
        card.append(element('h3', historical ? date : `${index === 0 ? 'Dzisiaj' : 'Jutro'} · ${date}`));
        const duration = typeof day.daylight_minutes === 'number' ? `${Math.floor(day.daylight_minutes / 60)} godz. ${day.daylight_minutes % 60} min` : '—';
        const list = element('dl', undefined, 'diagnostics');
        [['Wschód słońca', sunTime(day.sunrise), 'sunrise'], ['Zachód słońca', sunTime(day.sunset), 'sunset'], ['Długość dnia', duration, null]].forEach(([label, value, symbol]) => {
          const term = element('dt');
          if (symbol) term.append(icon(symbol), document.createTextNode(' '));
          term.append(document.createTextNode(label));
          list.append(term, element('dd', value));
        });
        card.append(list);
        if (day.polar) card.append(element('p', 'Brak pełnej pary wschód/zachód — warunki polarne.'));
        days.append(card);
      });
      byId('astronomy').append(days);
      if (!historical) {
        const timer = element('p'); timer.id = 'sun-countdown'; byId('astronomy').append(timer); tick();
      }
    }
    byId('alerts').replaceChildren();
    (data.alerts || []).forEach(alert => {
      const item = element('li');
      item.append(element('b', alert.label));
      item.append(element('p', `Zarejestrowano: ${timestamp(alert.since)}. Ostatnie potwierdzenie progu: ${timestamp(alert.last_confirmed_at)}.`));
      if (alert.stale) item.append(element('p', 'Brak aktualnych pomiarów — zdarzenie historyczne, obecne warunki nie są potwierdzone.'));
      byId('alerts').append(item);
    });
    if (!byId('alerts').children.length) byId('alerts').append(element('li','Brak aktywnych alertów.'));
  }

  async function refresh() {
    if (busy) return;
    busy = true;
    const version = requestVersion;
    try {
      const response = await fetch(`/api/weather?hours=${byId('range').value}&date=${encodeURIComponent(selectedDate)}`, { cache: 'no-store', signal: AbortSignal.timeout(8000) });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const data = await response.json();
      if (version === requestVersion) render(data);
    } catch (error) {
      byId('connection').classList.add('stale');
      byId('connection').textContent = 'Brak połączenia z serwerem';
      byId('notice').hidden = false;
      byId('notice').textContent = 'Nie można odświeżyć panelu. Ostatnio wyświetlone wartości mogą być nieaktualne. Ponawianie połączenia…';
    } finally { busy = false; if (version !== requestVersion) refresh(); }
  }
  function tick() {
    const timer = byId('sun-countdown');
    if (!timer || !latestData) return;
    const until = value => {
      if (!value) return '—';
      const seconds = Math.max(0, Math.ceil((Date.parse(value) - Date.now() - serverOffset) / 1000));
      if (!seconds) refresh();
      return [Math.floor(seconds / 3600), Math.floor(seconds % 3600 / 60), seconds % 60].map(n => String(n).padStart(2,'0')).join(':');
    };
    timer.textContent = `Do wschodu: ${until(latestData.astronomy?.next_sunrise)} · Do zachodu: ${until(latestData.astronomy?.next_sunset)}`;
  }
  setInterval(tick, 1000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) { tick(); refresh(); } });
  refresh();
  setInterval(refresh, 5000);
})();
