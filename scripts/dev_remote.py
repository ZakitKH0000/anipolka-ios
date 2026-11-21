"""Управление специальной тестовой сборкой АниПолки по Wi-Fi.

На iPhone: Настройки → «Специальная сборка» → «Управление с компьютера». Там видны адрес и токен.

    python scripts/dev_remote.py --host 192.168.1.5 --token abcd1234 ping
    python scripts/dev_remote.py state
    python scripts/dev_remote.py shot screen.jpg
    python scripts/dev_remote.py tree
    python scripts/dev_remote.py tap "Серии"            # по подписи кнопки (часть текста) или accessibilityIdentifier
    python scripts/dev_remote.py tap "Смотреть" --index 1
    python scripts/dev_remote.py scroll down | scroll up
    python scripts/dev_remote.py type "Фрирен" | type --return
    python scripts/dev_remote.py back | hide-keyboard
    python scripts/dev_remote.py tab 1                  # вкладки: 0 Коллекция, 1 Сегодня, 2 Обзор, 3 Серии, 4 Настройки
    python scripts/dev_remote.py open anipolka://entry/<UUID>
    python scripts/dev_remote.py backup copy.json       # копия коллекции на компьютер
    python scripts/dev_remote.py restore copy.json      # заменить коллекцию этой копией (осторожно)
    python scripts/dev_remote.py feedback               # сообщения «Предложить / Ошибка» из Студии
    python scripts/dev_remote.py feedback-image <id> shot.jpg | feedback-done <id>

Адрес и токен можно один раз задать переменными ANIPOLKA_HOST и ANIPOLKA_TOKEN.
Команды можно склеивать: python scripts/dev_remote.py tap Серии shot a.jpg — каждая выполняется по очереди.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

PORT = 8765


def call(host, token, method, path, query=None, body=None, raw=False):
    url = f"http://{host}:{PORT}{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    request = urllib.request.Request(url, data=body, method=method, headers={"X-Token": token})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
    except urllib.error.HTTPError as e:
        data = e.read()
    except urllib.error.URLError as e:
        sys.exit(f"Нет связи с iPhone ({e.reason}). Проверьте, что АниПолка открыта, переключатель включён и телефон в той же сети Wi-Fi.")
    if raw:
        return data
    try:
        return json.loads(data.decode("utf-8"))
    except ValueError:
        return {"raw": data[:500].decode("utf-8", "replace")}


def show(value):
    print(json.dumps(value, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default=os.environ.get("ANIPOLKA_HOST"))
    parser.add_argument("--token", default=os.environ.get("ANIPOLKA_TOKEN"))
    parser.add_argument("--index", type=int, default=0)
    parser.add_argument("--return", dest="ret", action="store_true")
    parser.add_argument("words", nargs="+")
    args = parser.parse_args()
    if not args.host or not args.token:
        sys.exit("Укажите --host и --token (их показывает АниПолка в Настройках → «Специальная сборка»).")
    if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
        sys.stdout.reconfigure(encoding="utf-8")
    h, t = args.host.split(":")[0], args.token
    words = list(args.words)
    takes = {"shot": 1, "tap": 1, "scroll": 1, "type": 1, "open": 1, "backup": 1, "restore": 1, "feedback-image": 1, "feedback-done": 1, "tab": 1}
    while words:
        command = words.pop(0)
        arg = words.pop(0) if takes.get(command) and words and not (command == "type" and args.ret) else None
        if command == "ping":
            show(call(h, t, "GET", "/ping"))
        elif command == "state":
            show(call(h, t, "GET", "/state"))
        elif command == "tree":
            for e in call(h, t, "GET", "/tree").get("elements", []):
                extra = (" #" + e["id"]) if e.get("id") else ""
                value = (" = " + e["value"]) if e.get("value") else ""
                print(f'{e["i"]:3} {"[кнопка] " if e.get("button") else ""}{e["label"]}{value}{extra}  {e["frame"]}')
        elif command == "shot":
            name = arg or "anipolka-screen.jpg"
            data = call(h, t, "GET", "/screenshot", {"format": "png"} if name.lower().endswith(".png") else None, raw=True)
            with open(name, "wb") as f:
                f.write(data)
            print("Снимок:", os.path.abspath(name), len(data), "байт")
        elif command == "tap":
            show(call(h, t, "POST", "/tap", {"label": arg or "", "index": args.index}))
        elif command == "scroll":
            show(call(h, t, "POST", "/scroll", {"dir": arg or "down"}))
        elif command == "type":
            show(call(h, t, "POST", "/type", {"key": "return"} if args.ret else {"text": arg or ""}))
        elif command == "tab":
            show(call(h, t, "POST", "/tab", {"index": arg or "0"}))
        elif command == "back":
            show(call(h, t, "POST", "/back"))
        elif command == "hide-keyboard":
            show(call(h, t, "POST", "/hide-keyboard"))
        elif command == "open":
            show(call(h, t, "POST", "/open", {"url": arg}))
        elif command == "feedback":
            for item in call(h, t, "GET", "/feedback").get("items", []):
                mark = "✓" if item.get("done") else "•"
                print(f'{mark} {item["id"]} [{item["kind"]}] {item["screen"]} · {item["at"]} · {item["version"]}\n   {item["text"]}')
        elif command == "feedback-image":
            ident = arg
            data = call(h, t, "GET", "/feedback-image", {"id": ident}, raw=True)
            name = (words.pop(0) if words else f"feedback-{ident[:8]}.jpg")
            with open(name, "wb") as f:
                f.write(data)
            print("Снимок сообщения:", os.path.abspath(name))
        elif command == "feedback-done":
            show(call(h, t, "POST", "/feedback-done", {"id": arg}))
        elif command == "backup":
            data = call(h, t, "GET", "/backup", raw=True)
            with open(arg or "anipolka-backup.json", "wb") as f:
                f.write(data)
            print("Копия сохранена:", os.path.abspath(arg or "anipolka-backup.json"), len(data), "байт")
        elif command == "restore":
            with open(arg, "rb") as f:
                show(call(h, t, "POST", "/restore", {"confirm": "yes"}, f.read()))
        else:
            sys.exit(f"Неизвестная команда: {command}")


if __name__ == "__main__":
    main()
