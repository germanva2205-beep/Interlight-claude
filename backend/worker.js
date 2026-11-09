// Сервер-посредник InterLight для Google Gemini (Cloudflare Worker).
// Ключ хранится только здесь, в секрете GEMINI_API_KEY, и в приложение не попадает.
// Маршруты: POST /recipes, /insight, /plate.

const MODEL = 'gemini-2.5-flash';

function reply(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
  });
}

async function gemini(env, parts) {
  const res = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'x-goog-api-key': env.GEMINI_API_KEY },
      body: JSON.stringify({
        contents: [{ parts }],
        generationConfig: { responseMimeType: 'application/json' },
      }),
    },
  );
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 300);
    throw new Error(`Gemini ${res.status}: ${detail}`);
  }
  const data = await res.json();
  const text = data?.candidates?.[0]?.content?.parts?.map((p) => p.text ?? '').join('') ?? '';
  if (!text) throw new Error('empty');
  return JSON.parse(text);
}

const img = (b64) => ({ inline_data: { mime_type: 'image/jpeg', data: b64 } });

async function recipes(env, body) {
  const ingredients = Array.isArray(body.ingredients) ? body.ingredients.slice(0, 30) : [];
  const maxKcal = Number(body.maxKcal) || 600;
  const meal = body.meal === 'ужин' ? 'ужин' : 'обед';
  const prompt =
    `Предложи 3 простых рецепта на ${meal} на русском языке из продуктов: ${ingredients.join(', ')}. ` +
    `Каждое блюдо — не больше ${maxKcal} ккал на порцию. Допустимы базовые добавки (соль, масло, специи). ` +
    'Верни JSON: {"recipes":[{"title":string,"minutes":number,"kcal":number,"protein":number,' +
    '"fat":number,"carbs":number,"ingredients":[string],"steps":[string]}]}. Белки, жиры, углеводы — в граммах.';
  const out = await gemini(env, [{ text: prompt }]);
  return { recipes: Array.isArray(out.recipes) ? out.recipes : [] };
}

async function insight(env, body) {
  const checkIns = Array.isArray(body.checkIns) ? body.checkIns.slice(-12) : [];
  const parts = [
    {
      text:
        'Ты дружелюбный помощник по заботе о себе. На русском языке, 2–3 коротких предложения, ' +
        'поддерживающим тоном, без медицинских советов, диагнозов и давления, без осуждения. ' +
        'Опиши динамику по чек-апам (вес в граммах, даты) и, если есть фото «первое» и «последнее», ' +
        'мягко отметь заметные визуальные изменения. Верни JSON: {"insight":string}. ' +
        `Данные: ${JSON.stringify(checkIns)}`,
    },
  ];
  if (body.photos?.first && body.photos?.last) {
    parts.push({ text: 'Первое фото:' }, img(body.photos.first), { text: 'Последнее фото:' }, img(body.photos.last));
  }
  const out = await gemini(env, parts);
  return { insight: String(out.insight ?? '') };
}

async function plate(env, body) {
  if (!body.photo) throw new Error('no photo');
  const prompt =
    'Определи блюда на фото тарелки и оцени вес и калорийность каждого. Названия на русском. ' +
    'Верни JSON: {"items":[{"name":string,"grams":number,"kcal":number}],' +
    '"confidence":"low"|"medium"|"high","note":string}. ' +
    'В note кратко напиши, что оценка приблизительная. Если еды на фото нет — items пустой.';
  return gemini(env, [{ text: prompt }, img(body.photo)]);
}

const ROUTES = { '/recipes': recipes, '/insight': insight, '/plate': plate };

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return reply({ error: 'POST only' }, 405);
    const handler = ROUTES[new URL(request.url).pathname];
    if (!handler) return reply({ error: 'not found' }, 404);
    try {
      return reply(await handler(env, await request.json()));
    } catch (e) {
      console.error(String(e?.message ?? e));
      return reply({ error: 'ai_failed' }, 502);
    }
  },
};
