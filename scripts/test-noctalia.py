#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 polyv0x
# SPDX-License-Identifier: GPL-3.0-or-later

"""Run the installed Noctalia and renderer in an isolated nested compositor.

Usage: python3 scripts/test-noctalia.py /path/to/hyprliquid
Only the temporary plugin copy gets the IPC inspection adapter. Logs/screenshots
stay in build/; no configuration or plugins in the live desktop are changed.
"""
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build'


def wait_for(check, processes, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        for process in processes:
            if process.poll() is not None:
                raise RuntimeError(f'Process exited ({process.returncode}); see build/noctalia-test.log')
        time.sleep(0.1)
    raise TimeoutError('Timed out; see build/noctalia-test.log')


def main():
    renderer = Path(sys.argv[1]).resolve()
    library = renderer / 'hyprliquid.so'
    assert library.exists(), f'Build {library} first'
    BUILD.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='hlq-ui-', dir='/tmp') as temporary, (BUILD / 'noctalia-test.log').open('w') as log:
        base = Path(temporary)
        env = os.environ.copy()
        parent_display = Path(env.get('WAYLAND_DISPLAY', 'wayland-1'))
        if not parent_display.is_absolute():
            parent_display = Path(env.get('XDG_RUNTIME_DIR', '/run/user/1000')) / parent_display
        env.update(XDG_RUNTIME_DIR=str(base), WAYLAND_DISPLAY=str(parent_display),
                   HYPRLAND_NO_SD_VARS='1', HYPRLAND_NO_SD_NOTIFY='1',
                   HYPRLIQUID_TEST_VIEW=str(base / 'view.json'))
        env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
        for kind in ('CONFIG', 'STATE', 'CACHE', 'DATA'):
            directory = str(base / kind.lower())
            env[f'XDG_{kind}_HOME'] = directory
            env[f'NOCTALIA_{kind}_HOME'] = directory
        config_dir = base / 'config/noctalia'
        config_dir.mkdir(parents=True)
        config = config_dir / 'config.toml'
        config.write_text('''[shell]
offline_mode = true
clipboard_enabled = false
polkit_agent = false
setup_wizard_enabled = false
[shell.animation]
enabled = false
[theme]
mode = "dark"
source = "builtin"
[theme.templates]
enable_builtin_templates = false
enable_community_templates = false
[wallpaper]
enabled = false
[plugins]
enabled = ["polyv0x/hyprliquid"]
auto_update = "none"
[[plugins.source]]
name = "official"
kind = "git"
location = "https://github.com/noctalia-dev/official-plugins"
enabled = false
[[plugins.source]]
name = "community"
kind = "git"
location = "https://github.com/noctalia-dev/community-plugins"
enabled = false
[bar.default]
start = ["glass"]
center = []
end = []
[widget.glass]
type = "polyv0x/hyprliquid:widget"
[[control_center.shortcuts]]
type = "polyv0x/hyprliquid:shortcut"
''')
        plugin = base / 'data/noctalia/plugins/hyprliquid'
        shutil.copytree(ROOT / 'hyprliquid', plugin)
        with (plugin / 'service.luau').open('a') as file:
            file.write('''
-- Test-only adapter: the installed plugin has no debug mutation interface.
local productionIpc = onIpc
noctalia.state.watch("request", function(value)
    noctalia.log("test UI request: " .. noctalia.json.encode(value))
end)
function onIpc(event, payload)
    if event == "test-request" then
        handle(noctalia.json.decode(payload))
    elseif event == "test-inspect" then
        noctalia.writeFile(noctalia.getenv("HYPRLIQUID_TEST_VIEW"), noctalia.json.encode(noctalia.state.get("view")))
    else productionIpc(event, payload) end
end
''')
        with (plugin / 'panel.luau').open('a') as file:
            file.write('''
function onIpc(event, payload)
    if event == "test-expand" then
        for _, group in ipairs(controls.groups) do expanded[group.name] = true end
        expanded.Profiles = true
        render()
    elseif event == "test-save" then
        profileName = payload
        saveProfile()
    elseif event == "test-cancel-overwrite" then
        cancelOverwrite()
    elseif event == "test-confirm-overwrite" then
        confirmOverwrite()
    elseif event == "test-inspect" then
        noctalia.writeFile(noctalia.getenv("HYPRLIQUID_TEST_VIEW") .. ".panel",
            noctalia.json.encode({ overwrite_name = overwriteName or "" }))
    end
end
''')
        compositor = subprocess.Popen(['Hyprland', '--config', str(renderer / 'tests/nested.lua')], env=env, stdout=log, stderr=log)
        shell = None
        # No activation directories: this test must not open a keyring prompt
        # or start desktop services belonging to the user's real session.
        bus_config = base / 'bus.conf'
        bus_config.write_text(f'''<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig><type>session</type><listen>unix:tmpdir={base}</listen>
<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>''')
        bus = subprocess.Popen(['dbus-daemon', '--config-file=' + str(bus_config), '--nofork', '--print-address=1'], stdout=subprocess.PIPE, stderr=log, text=True)
        env['DBUS_SESSION_BUS_ADDRESS'] = bus.stdout.readline().strip()
        env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + str(base / 'no-system-bus')
        try:
            socket = wait_for(lambda: next(base.glob('hypr/*/.socket.sock'), None), [compositor])
            display = wait_for(lambda: next((p for p in base.glob('wayland-*') if p.is_socket()), None), [compositor])
            env.update(HYPRLAND_INSTANCE_SIGNATURE=socket.parent.name, WAYLAND_DISPLAY=display.name)

            def run(argv, check=True):
                return subprocess.run(argv, env=env, text=True, capture_output=True, timeout=10, check=check)

            def ctl(*args):
                return run(['hyprctl', '-i', socket.parent.name, *args]).stdout.strip()

            def control(op, **fields):
                result = json.loads(ctl('hyprliquid:control', json.dumps({'op': op, **fields})))
                assert result['ok'], result
                return result['state']

            def msg(*args, check=True):
                return run(['noctalia', 'msg', *args], check)

            def start():
                process = subprocess.Popen(['noctalia'], env=env, stdout=log, stderr=log, start_new_session=True)
                try:
                    wait_for(lambda: msg('status', check=False).returncode == 0, [compositor, process])
                except Exception:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait(timeout=10)
                    raise
                return process

            def stop(process):
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)

            assert ctl('plugin', 'load', str(library)) == 'ok'
            validation = run(['noctalia', 'config', 'validate', str(config)])
            assert 'ERROR' not in validation.stdout, validation.stdout
            shell = start()

            def view():
                msg('plugin', 'polyv0x/hyprliquid:service', 'all', 'test-inspect')
                path = base / 'view.json'
                try:
                    return json.loads(path.read_text()) if path.exists() else {}
                except json.JSONDecodeError:
                    return {}

            def panel_view():
                msg('plugin', 'polyv0x/hyprliquid:panel', 'all', 'test-inspect')
                path = base / 'view.json.panel'
                try:
                    return json.loads(path.read_text()) if path.exists() else {}
                except json.JSONDecodeError:
                    return {}

            counter = 0

            def request(kind, **fields):
                nonlocal counter
                counter += 1
                ident = f'test:{counter}'
                msg('plugin', 'polyv0x/hyprliquid:service', 'all', 'test-request', json.dumps({'kind': kind, 'id': ident, **fields}))
                try:
                    return wait_for(lambda: (v if (v := view()).get('ack') == ident and not v.get('pending') else None), [compositor, shell])
                except TimeoutError:
                    current = view()
                    raise RuntimeError(f'Request {ident} timed out: ' + repr({key: current.get(key) for key in ('ack', 'pending', 'error', 'draft')}))

            ready = wait_for(lambda: (v if (v := view()).get('available') else None), [compositor, shell])
            assert len(ready['descriptor']['parameters']) == 33
            msg('panel-toggle', 'polyv0x/hyprliquid:panel')
            time.sleep(0.6)
            run(['grim', str(BUILD / 'noctalia-panel.png')])
            msg('plugin', 'polyv0x/hyprliquid:panel', 'all', 'test-expand')
            for preset in ['frosted', 'soft-glass', 'clear-glass', 'frosted-glass', 'clear-edge']:
                for theme in ('dark', 'light'):
                    themed = request('edit', profile={'base_preset': preset, 'enabled': True, 'overrides': {}},
                                     theme_mode=theme, flush=True)
                    assert not themed.get('error') and themed['theme_mode'] == theme, themed
                    current = control('state')
                    assert current['theme'] == theme and current['panel']['overrides'] == {}
                    assert math.isclose(current['material']['face_intercept'], 0.06 if theme == 'dark' else 0.30, abs_tol=1e-6)
            print('PASS: panel service selects real dark/light material variants for all five presets', flush=True)
            profile = {'base_preset': 'soft-glass', 'enabled': True, 'overrides': {'inner_refraction_amount': -43, 'coverage_offset': -0.45, 'rim_opacity': 0.15, 'neighbor_contribution': 0.375, 'neighbor_falloff': 0.5}}
            edited = request('edit', profile=profile, theme_mode='follow', flush=True)
            assert not edited.get('error'), edited
            assert control('state')['material']['inner_refraction_amount'] == -43
            assert control('state')['material']['neighbor_contribution'] == 0.375
            assert control('state')['material']['neighbor_falloff'] == 0.5
            before_invalid = control('state')
            invalid = request('edit', profile={**profile, 'overrides': {'rim_opacity': 999, 'blur_sigma': 5}}, theme_mode='dark', flush=True)
            assert invalid.get('error') and control('state') == before_invalid
            request('edit', profile=profile, theme_mode='follow', flush=True)
            saved = request('save', new_name='Signed glass')
            assert saved['selected'] == 'Signed_glass' and not saved.get('storage_error'), saved
            path = next((base / 'state').rglob('profiles.json'))
            assert json.loads(path.read_text())['profiles'][0]['overrides']['coverage_offset'] < 0
            assert json.loads(path.read_text())['profiles'][0]['overrides']['neighbor_contribution'] == 0.375
            assert json.loads(path.read_text())['profiles'][0]['overrides']['neighbor_falloff'] == 0.5
            updated_profile = {**profile, 'overrides': {**profile['overrides'], 'coverage_offset': -0.55}}
            request('edit', profile=updated_profile, theme_mode='follow', flush=True)
            before_overwrite, before_renderer = path.read_text(), control('state')
            msg('plugin', 'polyv0x/hyprliquid:panel', 'all', 'test-save', 'Signed glass')
            wait_for(lambda: panel_view().get('overwrite_name') == 'Signed_glass', [compositor, shell])
            time.sleep(0.2)
            run(['grim', str(BUILD / 'noctalia-overwrite-dialog.png')])
            assert path.read_text() == before_overwrite and not view().get('error')
            msg('plugin', 'polyv0x/hyprliquid:panel', 'all', 'test-cancel-overwrite')
            wait_for(lambda: panel_view().get('overwrite_name') == '', [compositor, shell])
            assert path.read_text() == before_overwrite, 'Cancel changed the saved profile'
            msg('plugin', 'polyv0x/hyprliquid:panel', 'all', 'test-save', 'Signed glass')
            wait_for(lambda: panel_view().get('overwrite_name') == 'Signed_glass', [compositor, shell])
            msg('plugin', 'polyv0x/hyprliquid:panel', 'all', 'test-confirm-overwrite')
            wait_for(lambda: math.isclose(view()['profiles'][0]['overrides']['coverage_offset'], -0.55, abs_tol=1e-6),
                     [compositor, shell])
            overwritten = json.loads(path.read_text())
            assert len(overwritten['profiles']) == 1 and overwritten['selected'] == 'Signed_glass'
            assert math.isclose(overwritten['profiles'][0]['overrides']['coverage_offset'], -0.55, abs_tol=1e-6)
            assert control('state') == before_renderer, 'Overwrite reapplied the renderer'
            print('PASS: real overwrite dialog, cancellation and confirmed profile replacement', flush=True)
            msg('theme-mode-set', 'light')
            wait_for(lambda: control('state')['theme'] == 'light', [compositor, shell])
            followed = control('state')['material']
            assert math.isclose(followed['face_intercept'], 0.30, abs_tol=1e-6)
            assert math.isclose(followed['rim_opacity'], 0.15, abs_tol=1e-6), 'Theme following replaced an explicit slider override'
            print('PASS: real Noctalia VM, panel, signed JSON IPC, atomic profiles and follow-theme', flush=True)

            revision = control('state')['revision']
            stop(shell); shell = None
            assert control('state')['revision'] == revision, 'Noctalia exit changed renderer'
            legacy = json.loads(path.read_text())
            legacy['current']['overrides']['use_measured_face'] = 0.5
            legacy['profiles'][0]['overrides']['use_measured_face'] = 0
            path.write_text(json.dumps(legacy))
            shell = start()
            restored = wait_for(lambda: (v if (v := view()).get('available') else None), [compositor, shell])
            assert restored['selected'] == 'Signed_glass', restored
            assert control('state')['revision'] == revision, 'Restart unnecessarily reapplied matching profile'
            assert control('state')['material']['neighbor_contribution'] == 0.375
            assert control('state')['material']['neighbor_falloff'] == 0.5
            ctl('reload')
            msg('plugin', 'polyv0x/hyprliquid:service', 'all', 'refresh')
            wait_for(lambda: control('state')['material']['inner_refraction_amount'] == -43, [compositor, shell])
            assert control('state')['material']['neighbor_contribution'] == 0.375
            assert control('state')['material']['neighbor_falloff'] == 0.5
            renamed = request('rename', name='Signed_glass', new_name='Renamed glass')
            assert renamed['selected'] == 'Renamed_glass'
            request('reset')
            selected = request('select', name='Renamed_glass')
            assert selected['selected'] == 'Renamed_glass'
            assert control('state')['material']['neighbor_contribution'] == 0.375
            assert control('state')['material']['neighbor_falloff'] == 0.5
            control('apply', patch={'overrides': {'inner_refraction_amount': -17}})
            msg('plugin', 'polyv0x/hyprliquid:service', 'all', 'refresh')
            wait_for(lambda: view().get('selected') == '', [compositor, shell])
            assert control('state')['material']['inner_refraction_amount'] == -17
            request('delete', name='Renamed_glass')
            assert control('state')['material']['inner_refraction_amount'] == -17
            before_disable = control('state')
            msg('plugins', 'disable', 'polyv0x/hyprliquid')
            time.sleep(0.2)
            assert control('state') == before_disable, 'Disabling frontend changed renderer'
            msg('plugins', 'enable', 'polyv0x/hyprliquid')
            wait_for(lambda: view().get('available'), [compositor, shell])
            print('PASS: real restart/reload, profile migration, save/select/rename/delete and terminal ownership', flush=True)

            assert ctl('plugin', 'unload', str(library)) == 'ok'
            msg('plugin', 'polyv0x/hyprliquid:service', 'all', 'refresh')
            wait_for(lambda: not view().get('available', True), [compositor, shell])
            assert ctl('plugin', 'load', str(library)) == 'ok'
            msg('plugin', 'polyv0x/hyprliquid:service', 'all', 'refresh')
            wait_for(lambda: view().get('available'), [compositor, shell])
            print('PASS: missing renderer recovers after unload/reload', flush=True)
            log.flush()
            errors = [line for line in (BUILD / 'noctalia-test.log').read_text().splitlines()
                      if 'hyprliquid' in line.lower() and any(term in line.lower() for term in ('error', 'unknown prop', 'invalid prop', 'failed'))]
            assert not errors, '\n'.join(errors)
        finally:
            if (base / 'view.json').exists():
                shutil.copyfile(base / 'view.json', BUILD / 'noctalia-last-view.json')
            if shell and shell.poll() is None:
                os.killpg(shell.pid, signal.SIGTERM)
                shell.wait(timeout=10)
            if compositor.poll() is None:
                compositor.terminate()
                compositor.wait(timeout=10)
            if bus.poll() is None:
                bus.terminate()
                bus.wait(timeout=10)


if __name__ == '__main__':
    main()
