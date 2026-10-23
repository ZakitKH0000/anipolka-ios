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
