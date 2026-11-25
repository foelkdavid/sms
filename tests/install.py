"""Installation integration check; all user paths are temporary."""
import os
import pwd
import shutil
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
    # Use sleep as a display-independent running executable at the install path.
    shutil.copyfile('/bin/sleep', binary)
    running = subprocess.Popen([str(binary), '30'])
    try:
        target('install')
        assert running.poll() is None, 'reinstall must not stop the running app'
        assert binary.read_bytes() == (ROOT / 'build/sms').read_bytes()
    finally:
        running.terminate()
        running.wait()
    text = desktop.read_text()
    real_home = pwd.getpwuid(os.getuid()).pw_dir   # the launcher must use the test home, not the real one
    assert '@EXEC@' not in text and '--fallback-home %f' in text and 'MimeType=inode/directory;' in text and real_home not in text
    if shutil.which('desktop-file-validate'):
        subprocess.run(['desktop-file-validate', str(desktop)], check=True)
    for name in ('FONT-OFL.txt', 'RAYLIB-LICENSE.txt', 'BMU-LICENSE.txt'):
        assert (data / 'sms/licenses' / name).read_bytes() == (ROOT / 'licenses' / name).read_bytes()
    unrelated = data / 'sms/keep'
    unrelated.write_text('keep')
    target('uninstall')
    target('uninstall')
    assert not binary.exists() and not desktop.exists()
    assert not (data / 'sms/licenses').exists()
    assert unrelated.read_text() == 'keep'
    assert settings.read_text() == 'preserve me'

    # The standalone release installer must generate the same directory-handler launcher.
    package = base / 'release'
    package.mkdir()
    for source, name in ((ROOT / 'build/sms', 'sms'), (ROOT / 'sms.desktop', 'sms.desktop'),
                         (ROOT / 'assets/sms.svg', 'sms.svg')):
        shutil.copyfile(source, package / name)
    shutil.copytree(ROOT / 'licenses', package / 'licenses')
    for name in ('install', 'uninstall'):
        shutil.copyfile(ROOT / 'release' / name, package / name)
    subprocess.run(['sh', str(package / 'install')], env=env, check=True)
    # Python escapes spaces as \\s; the shell installer leaves them inside quotes.
    assert desktop.read_text() == text.replace('\\s', ' ')
    if shutil.which('desktop-file-validate'):
        subprocess.run(['desktop-file-validate', str(desktop)], check=True)
    assert binary.read_bytes() == (ROOT / 'build/sms').read_bytes()
    subprocess.run(['sh', str(package / 'uninstall')], env=env, check=True)
    assert not binary.exists() and not desktop.exists()
    assert unrelated.read_text() == 'keep'
    assert settings.read_text() == 'preserve me'

    # Keep a simple executable unquoted: xdg-open's generic parser needs this.
    env['HOME'] = str(base / 'simple-home')
    subprocess.run(['python3', str(ROOT / 'scripts/install.py'), 'install'], env=env, check=True)
    simple_exec = f"Exec={env['HOME']}/.local/bin/sms --fallback-home %f"
    assert simple_exec in desktop.read_text().splitlines()
    subprocess.run(['sh', str(package / 'install')], env=env, check=True)
    assert simple_exec in desktop.read_text().splitlines()
    subprocess.run(['sh', str(package / 'uninstall')], env=env, check=True)
print('Installation checks passed.')
