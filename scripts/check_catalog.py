"""Live public-catalogue contract checks; no account, app build or personal collection."""
import json
import time
import urllib.parse
import urllib.request

HEADERS = {'User-Agent': 'AniPolka/1.1 (public cover verification)'}


def fetch(url, payload=None):
    for attempt in range(3):
        try:
            headers = dict(HEADERS)
            if 'kitsu.io/' in url:
                headers['Accept'] = 'application/vnd.api+json'
            if payload is not None:
                headers['Content-Type'] = 'application/json'
            body = json.dumps(payload).encode() if payload is not None else None
            request = urllib.request.Request(url, data=body, headers=headers)
            with urllib.request.urlopen(request, timeout=25) as response:
                return response.read(12_000_001), response.headers.get_content_type(), response.url
        except Exception:
            if attempt == 2:
                raise
            time.sleep(3)


def poster(url):
    assert url.startswith('https://') and '/assets/globals/missing_' not in url
    data, content_type, final_url = fetch(url)
    assert content_type.startswith('image/') and '/assets/globals/missing_' not in final_url
    assert 1000 < len(data) <= 12_000_000
    assert data.startswith((b'\xff\xd8\xff', b'\x89PNG\r\n\x1a\n')) or (data[:4] == b'RIFF' and data[8:12] == b'WEBP'), 'Not a JPEG, PNG or WebP image'


def kitsu(query):
    params = urllib.parse.urlencode({'filter[text]': query, 'page[limit]': 20})
    return json.loads(fetch('https://kitsu.io/api/edge/anime?' + params)[0])['data']


# New Shikimori posters are supplied by GraphQL, while old REST can return an
# HTTP 200 image containing "404 not found" for the same anime ID.
query = 'query($value: String!) { animes(ids: $value, limit: 30, censored: true) { id name russian url kind episodes airedOn { year month day } poster { originalUrl mainUrl } } }'
response = json.loads(fetch('https://shikimori.io/api/graphql', {'query': query, 'variables': {'value': '44218,60416'}})[0])
assert not response.get('errors')
items = {int(item['id']): item for item in response['data']['animes']}
assert items[60416]['name'] == 'Wu Lian Dianfeng'
assert items[60416]['airedOn']['year'] == 2024
for anime_id in [44218, 60416]:
    poster(items[anime_id]['poster']['originalUrl'])
print('Shikimori GraphQL: both exact catalogue IDs have real image responses, including a legacy-placeholder regression title.')
time.sleep(1.1)

results = kitsu('Tunshi Xingkong')
chosen = next(item['attributes'] for item in results if item['id'] == '43803')
assert chosen['canonicalTitle'] == 'Tunshi Xingkong'
assert any(item['attributes']['canonicalTitle'] == 'Tunshi Xingkong 2nd Season' for item in results)
poster(chosen['posterImage']['large'])
print('Kitsu: original title, distinct second season and real poster remain available.')
time.sleep(1.1)

# Publicly available backup for a Chinese title. The deterministic Swift tests
# inject primary failures; this check verifies the alternate service contract.
results = kitsu('Mushen Ji')
chosen = next(item['attributes'] for item in results if item['attributes']['canonicalTitle'] == 'Mushen Ji')
assert chosen['startDate'][:4] == '2024' and chosen['subtype'].lower() == 'ona'
assert 'Mushen Ji' in chosen['titles'].values()
poster(chosen['posterImage']['large'])
print('Kitsu fallback contract: original donghua title, matching year/type and real poster available without an API key.')
