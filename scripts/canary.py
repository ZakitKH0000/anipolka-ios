"""Daily canary: do the public sources still answer in the format AniPolka reads?

Run by .github/workflows/canary.yml. Exits with 1 when any source changed or is down,
so GitHub sends the owner a failure e-mail. Only public pages are read; nothing is stored.
"""
import json
import re
import sys
import urllib.parse
import urllib.request

UA = {"User-Agent": "AniPolka/1.4 canary (personal episode tracker)"}


def fetch(url, body=None, accept="application/json"):
    headers = dict(UA, Accept=accept)
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode()
    with urllib.request.urlopen(urllib.request.Request(url, data=data, headers=headers), timeout=30) as r:
        return r.status, r.read().decode("utf-8", "replace")


def json_after(text, marker):
    """Same idea as AnivibePageParser.jsonValue: one balanced JSON value after a marker."""
    i = text.find(marker)
    if i < 0:
        return None
    i += len(marker)
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text) or text[i] not in "{[":
        return None
    depth, in_str, esc = 0, False, False
    for j in range(i, len(text)):
        ch = text[j]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
            if depth == 0:
                return text[i:j + 1]
    return None


def anivibe():
    status, xml = fetch("https://anivibe.pro/sitemap.xml", accept="application/xml")
    assert status == 200 and "<loc>" in xml, "sitemap.xml без <loc>"
    status, page = fetch("https://anivibe.pro/anime/44218", accept="text/html")
    assert status == 200, f"страница ответила {status}"
    kodik = json_after(page, "const kodikData =")
    vidoza = json_after(page, "window.__vidozaData = window.__unpackVidozaGroups(")
    assert kodik or vidoza, "нет ни kodikData, ни __vidozaData — формат страницы изменился"
    episodes = []
    if kodik:
        episodes += [t.get("last_episode") for t in json.loads(kodik).get("translations", []) if isinstance(t.get("last_episode"), int)]
    if vidoza:
        episodes += [e.get("e") for g in json.loads(vidoza) for e in g.get("eps", []) if isinstance(e.get("e"), int)]
    assert episodes, "на странице нет номеров серий"
    return f"озвучек/серий найдено: {len(episodes)}"


def shikimori():
    q = "query($ids: String!) { animes(ids: $ids, limit: 5) { id franchise japanese status episodes episodesAired nextEpisodeAt } }"
    _, text = fetch("https://shikimori.io/api/graphql", {"query": q, "variables": {"ids": "64710"}})
    data = json.loads(text)
    assert "errors" not in data, f"GraphQL: {data.get('errors')}"
    assert data["data"]["animes"], "пустой ответ"
    return "поля расписания на месте"


def anilibria():
    _, text = fetch("https://anilibria.top/api/v1/anime/schedule/week")
    items = json.loads(text)
    assert isinstance(items, list) and items and "release" in items[0], "расписание не список релизов"
    return f"в расписании {len(items)}"


def bangumi():
    _, text = fetch("https://api.bgm.tv/search/subject/" + urllib.parse.quote("太古神尊") + "?type=2&responseGroup=small&max_results=5")
    found = [x for x in json.loads(text).get("list") or [] if x.get("name") == "太古神尊"]
    assert found, "поиск не нашёл точное название"
    _, text = fetch(f"https://api.bgm.tv/v0/episodes?subject_id={found[0]['id']}&type=0&limit=5")
    assert json.loads(text).get("data"), "нет списка серий"
    return "поиск и серии работают"


def telegram():
    _, page = fetch("https://t.me/s/fumodub", accept="text/html")
    posts = re.findall(r'data-post="[^"]+"', page)
    assert posts and "tgme_widget_message_text" in page, "нет постов в превью канала"
    return f"постов в превью: {len(posts)}"


def main():
    failed = 0
    for name, check in [("AniVibe", anivibe), ("Shikimori", shikimori), ("AniLibria", anilibria), ("Bangumi", bangumi), ("Telegram", telegram)]:
        try:
            print(f"OK   {name}: {check()}")
        except Exception as error:  # noqa: BLE001 — every failure is reported, none stops the others
            failed += 1
            print(f"FAIL {name}: {error}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
