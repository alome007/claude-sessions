export async function api(path, data) {
  const request = data === undefined
    ? {}
    : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) };
  const response = await fetch(path, request);
  const body = await response.json();
  if (!response.ok) throw new Error(body.error);
  return body;
}
