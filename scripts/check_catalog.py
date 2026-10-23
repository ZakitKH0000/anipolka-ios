"""Ограниченная живая проверка публичного поиска и связанной с результатом обложки."""
import json
import urllib.parse
import urllib.request
import time

headers = {'User-Agent': 'AniPolka/1.0 (personal iOS collection)'}
query = urllib.parse.urlencode({'search':'Tunshi Xingkong','limit':10,'censored':'true'})
for attempt in range(3):
    try:
        with urllib.request.urlopen(urllib.request.Request('https://shikimori.io/api/animes?' + query, headers=headers),timeout=25) as r:
            results = json.load(r)
        chosen = next(x for x in results if x['id'] == 44218)
        image = urllib.parse.urljoin('https://shikimori.io',chosen['image']['original'])
        with urllib.request.urlopen(urllib.request.Request(image,headers=headers),timeout=25) as r:
            assert r.status == 200 and r.headers.get_content_type().startswith('image/')
            assert len(r.read(12000000)) > 1000
        print('Живой API: китайский сериал, варианты сезонов и связанная обложка доступны; ключ не требуется.')
        break
    except Exception:
        if attempt == 2: raise
        time.sleep(3)

for attempt in range(3):
    try:
        query = urllib.parse.urlencode({'filter[text]':'Tunshi Xingkong','page[limit]':10})
        request = urllib.request.Request('https://kitsu.io/api/edge/anime?' + query,headers={**headers,'Accept':'application/vnd.api+json'})
        with urllib.request.urlopen(request,timeout=25) as r:
            results = json.load(r)['data']
        chosen = next(x['attributes'] for x in results if x['id'] == '43803')
        assert chosen['canonicalTitle'] == 'Tunshi Xingkong'
        assert any(x['attributes']['canonicalTitle'] == 'Tunshi Xingkong 2nd Season' for x in results)
        with urllib.request.urlopen(urllib.request.Request(chosen['posterImage']['large'],headers=headers),timeout=25) as r:
            assert r.status == 200 and r.headers.get_content_type().startswith('image/')
            assert len(r.read(12000000)) > 1000
        print('Kitsu: китайский сериал, отдельный второй сезон и связанная обложка доступны без ключа.')
        break
    except Exception:
        if attempt == 2: raise
        time.sleep(3)
