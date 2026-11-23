"""Installation integration check; all user paths are temporary."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="sms-install-") as temporary:
    base = Path(temporary)
    home = base / 'home with spaces'
    data = base / 'data'
    config = base / 'config'
    settings = config / 'sms/settings'
    settings.parent.mkdir(parents=True)
    settings.write_text('preserve me')
    env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(data), XDG_CONFIG_HOME=str(config))

    def target(name):
        subprocess.run(['c3c', 'build', name, '--trust=full'], cwd=ROOT, env=env, check=True)

    target('install')
    binary = home / '.local/bin/sms'
    desktop = data / 'applications/sms.desktop'
    assert binary.read_bytes() == (ROOT / 'build/sms').read_bytes()
    assert os.access(binary, os.X_OK)
    text = desktop.read_text()
    assert '@EXEC@' not in text and '--dir' in text and '~' not in text
    for name in ('FONT-OFL.txt', 'RAYLIB-LICENSE.txt'):
        assert (data / 'sms/licenses' / name).read_bytes() == (ROOT / 'licenses' / name).read_bytes()
    unrelated = data / 'sms/keep'
    unrelated.write_text('keep')
    target('uninstall')
    target('uninstall')
    assert not binary.exists() and not desktop.exists()
    assert not (data / 'sms/licenses').exists()
    assert unrelated.read_text() == 'keep'
    assert settings.read_text() == 'preserve me'
print('Installation checks passed.')
