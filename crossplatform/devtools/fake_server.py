"""無 iPhone 時啟動 app.py 的 UI（假 pymobiledevice3 + 暫存狀態目錄 + 別的 port）。

  py devtools/fake_server.py [port]      # 預設 18765，不開瀏覽器、不碰 ~/.fakegps
環境變數見 fake_pmd3/pymobiledevice3/__main__.py。整個 devtools/ 可直接刪除。
"""
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
os.environ["PYTHONPATH"] = os.pathsep.join([str(HERE / "fake_pmd3"), os.environ.get("PYTHONPATH", "")])
sys.path.insert(0, str(HERE.parent))
import app  # noqa: E402

state = Path(tempfile.mkdtemp(prefix="fakegps-"))
app.BOOKMARKS, app.RECENTS, app.ROUTE_GPX = state / "bookmarks.json", state / "recents.json", state / "route.gpx"
app.PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18765
app.webbrowser.open = lambda *a, **k: None
print(f"state dir: {state}")
app.main()
