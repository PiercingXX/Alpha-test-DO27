#!/usr/bin/env bash
# Update/autolaunch tests for install.sh + the do27 command. Run on the test rig, CPU only, scratch HOME.
#   run_tests.sh WORKTREE [OLD_INSTALL_SH]      (OLD_INSTALL_SH: the v0.1.1 installer, to test its old do27 command)
# Everything lives under $T (default /srv/fast2/do27/update_test); the real ~ and ~/.config/DO27 are never touched.
set -u
WT=$(cd "$1" && pwd); OLD=${2:-}
T=${T:-/srv/fast2/do27/update_test}; PORT=${PORT:-8101}; RATE=${RATE:-500000}
M=http://127.0.0.1:$PORT
HERE=$WT/tests/update_autolaunch
pass=0; fail=0
want() { [ -z "${ONLY:-}" ] || [[ " $ONLY " == *" $1 "* ]]; }
ok()  { echo "PASS  $*"; pass=$((pass + 1)); }
bad() { echo "FAIL  $*"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }

# Guard: the real HOME must stay untouched (every player below has its own scratch HOME).
real_stamp() { stat -c %Y "$REAL_HOME/.local/bin/do27" "$REAL_HOME/.local/share/applications/do27-alpha.desktop" "$REAL_HOME/.local/share/do27-alpha" "$REAL_HOME/.local/share/do27-alpha/LICENSE-ALPHA.txt" 2>&1; }
REAL_HOME=$HOME; stamp0=$(real_stamp)
pkill -f "serve.py $T/mirror" 2>/dev/null; sleep 0.3
rm -rf "$T"; mkdir -p "$T/mirror/assets" "$T/stubs" "$T/logs"
# Stubs: zenity logs what the progress window would show; notify-send logs notifications.
cat > "$T/stubs/zenity" <<'S'
#!/usr/bin/env bash
echo "zenity $*" >> "$STUBLOG"
case " $* " in *" --progress "*) while IFS= read -r l; do echo "progress: $l" >> "$STUBLOG"; done ;; esac
S
cat > "$T/stubs/notify-send" <<'S'
#!/usr/bin/env bash
echo "notify $*" >> "$STUBLOG"
S
chmod +x "$T/stubs/"*
mkdir -p "$T/stubs2"; cp "$T/stubs/notify-send" "$T/stubs2/"   # a PATH with notify-send but no zenity
cp "$WT/install.sh" "$T/mirror/install.sh"
setsid -f python3 -I "$HERE/serve.py" "$T/mirror" "$PORT" "$RATE" >"$T/logs/server.log" 2>&1
sleep 1
python3 -I "$HERE/mkmirror.py" "$T/mirror" "$M" publish v0.1.0 || exit 1

# env for a fresh scratch player: no tty (setsid), a "display" so the zenity path is chosen
new_home() {  # new_home NAME
  H=$T/$1; rm -rf "$H"; mkdir -p "$H"; : > "$T/logs/$1.stub"
}
runp() { # runp NAME CMD...  : run as that player, no terminal
  local n=$1; shift
  env HOME=$T/$n XDG_CACHE_HOME=$T/$n/.cache XDG_CONFIG_HOME=$T/$n/.config PATH=$T/stubs:$PATH STUBLOG=$T/logs/$n.stub \
      DISPLAY=:99 DO27_ALPHA_MIRROR=$M "$@"
}
install_as() { # install_as NAME INSTALLER   (fresh install of the published release, terminal-less, text mode)
  runp "$1" DO27_TIER=low DO27_SKIP_PREPARE=1 DO27_AUTOUPDATE=1 DO27_UI=none bash "$2" </dev/null >"$T/logs/$1.install" 2>&1
}
launch() { # launch NAME [extra env]  : the app-menu start of the do27 command
  local n=$1; shift
  setsid -f env HOME=$T/$n XDG_CACHE_HOME=$T/$n/.cache XDG_CONFIG_HOME=$T/$n/.config PATH=$T/stubs:$PATH STUBLOG=$T/logs/$n.stub DISPLAY=:99 "$@" \
    "$T/$n/.local/bin/do27" </dev/null >>"$T/logs/$n.out" 2>&1
}
waitfor() { local i; for i in $(seq 1 "$2"); do eval "$1" && return 0; sleep 1; done; return 1; }
starts() { grep -c '^started' "$T/$1/game-started.marker" 2>/dev/null || echo 0; }
ver() { cat "$T/$1/.local/share/do27-alpha/VERSION" 2>/dev/null; }

echo "== setup: install v0.1.0 with the NEW installer (writes the new do27 command)"
new_home new; install_as new "$T/mirror/install.sh"
check "v0.1.0 installed" '[ "$(ver new)" = v0.1.0 ]'
check "new wrapper written" 'grep -q "wrapper 2" $T/new/.local/bin/do27'

python3 -I "$HERE/mkmirror.py" "$T/mirror" "$M" publish v0.1.1 || exit 1
: > "$T/mirror/requests.log"

if want T1; then
echo "== T1: app-menu start (no tty): update runs with progress, then the game starts by itself"
launch new
check "game started after the update" 'waitfor "[ \$(starts new) -ge 1 ]" 90'
check "exactly one game start" '[ "$(starts new)" = 1 ]'
check "VERSION is v0.1.1" '[ "$(ver new)" = v0.1.1 ]'
check "progress window showed part n of N" 'grep -q "progress: # Updating to v0.1.1: part 3 of 5" $T/logs/new.stub'
check "progress window showed the size and an estimate" 'grep -Eq "progress: # .*part [0-9] of 5, (downloading|unpacking) \([0-9.]+ MB of [0-9.]+ MB(, (about|under) )?" $T/logs/new.stub'
check "progress percent rose to 100" 'grep -q "^progress: 100" $T/logs/new.stub'
check "done notice shown" 'grep -q "Update done, starting Direct Order 27" $T/logs/new.stub'
check "the game did not inherit the lock fd (9)" '! grep -E "^[0-9 ]*\b9\b" <(grep -v started $T/new/game-started.marker) >/dev/null'
check "only the 5 changed parts were requested" '[ "$(grep -c "^/assets/.*zst -" $T/mirror/requests.log)" = 5 ]'
check "update.progress removed" '[ ! -e $T/new/.local/share/do27-alpha/update.progress ]'
check "lock free after the game started" 'flock -n $T/new/.local/share/do27-alpha/update.lock true'
check "the next start does not update again" 'launch new; waitfor "[ \$(starts new) -ge 2 ]" 20'

fi
rewind() {  # rewind NAME : a v0.1.0 player (installed from a v0.1.0 mirror state)
  python3 -I "$HERE/mkmirror.py" "$T/mirror" "$M" publish v0.1.0 >/dev/null
  # the v0.1.0 release is the latest again only while installing
  new_home "$1"; install_as "$1" "$2"
  python3 -I "$HERE/mkmirror.py" "$T/mirror" "$M" publish v0.1.1 >/dev/null
}
if want T2; then
echo "== T2: kill -9 midway, start again: resumes (no re-download of finished parts)"
rewind kill "$T/mirror/install.sh"
: > "$T/mirror/requests.log"
launch kill
waitfor 'grep -q "Part 3 of 5" $T/kill/.local/share/do27-alpha/update.log 2>/dev/null' 90
sleep 2
pg=$(pgrep -f "$T/kill/.local/bin/do27" | head -1)
pkill -9 -f "$T/kill/.local/share/do27-alpha/.install" 2>/dev/null; pkill -9 -f "$T/kill/.local/bin/do27"; pkill -9 -f "curl.*127.0.0.1:$PORT"; pkill -9 -f "bash $T/kill/.local/share/do27-alpha/.install" 2>/dev/null
sleep 1
check "killed: still v0.1.0 and no game start yet" '[ "$(ver kill)" = v0.1.0 ] && [ "$(starts kill)" = 0 ]'
inst_before=$(ls $T/kill/.local/share/do27-alpha/chunks | wc -l)
check "killed: finished parts are on disk (state + download dir)" '[ -d $T/kill/.local/share/do27-alpha/.download ]'
: > "$T/mirror/requests.log"
launch kill
check "resumed: game started" 'waitfor "[ \$(starts kill) -ge 1 ]" 90'
check "resumed: VERSION is v0.1.1" '[ "$(ver kill)" = v0.1.1 ]'
check "resumed: says it carries on" 'grep -q "Carrying on:" $T/kill/.local/share/do27-alpha/update.log'
check "resumed: numbering continues of 5" 'grep -q "Part [34] of 5" $T/kill/.local/share/do27-alpha/update.log && ! grep -q "of 2\b" $T/kill/.local/share/do27-alpha/update.log'
n=$(grep -c "^/assets/.*zst" "$T/mirror/requests.log")
check "resumed: fewer than 5 parts requested again ($n)" '[ "$n" -lt 5 ]'
check "resumed: a partial part continued with a Range request" 'grep -q "^/assets/.*zst bytes=[1-9]" $T/mirror/requests.log || [ "$n" -le 3 ]'

fi
if want T3; then
echo "== T3: double click while updating takes the lock"
rewind dbl "$T/mirror/install.sh"
launch dbl
waitfor 'grep -q "Part 2 of 5" $T/dbl/.local/share/do27-alpha/update.log 2>/dev/null' 90
launch dbl
sleep 3
check "second click: Already updating (part n of 5)" 'grep -Eq "Already updating \(part [0-9] of 5\)" $T/logs/dbl.out $T/logs/dbl.stub'
check "second click started no game while updating" '[ "$(starts dbl)" = 0 ]'
check "one download only (every part requested once)" '[ "$(grep "^/assets/.*zst -" $T/mirror/requests.log | sort | uniq -d | wc -l)" = 0 ]'
check "first update finishes and starts exactly one game" 'waitfor "[ \$(starts dbl) -ge 1 ]" 90 && sleep 2 && [ "$(starts dbl)" = 1 ]'

fi
if want T4; then
echo "== T4: failed update (server down) still starts the installed game"
rewind fail "$T/mirror/install.sh"
: > "$T/mirror/requests.log"
pkill -f "serve.py $T/mirror"; sleep 0.5
launch fail
check "offline: the installed version starts" 'waitfor "[ \$(starts fail) -ge 1 ]" 40'
check "offline: still v0.1.0" '[ "$(ver fail)" = v0.1.0 ]'
setsid -f python3 -I "$HERE/serve.py" "$T/mirror" "$PORT" "$RATE" >>"$T/logs/server.log" 2>&1; sleep 1
echo "-- failure mid-update: serve a part with a wrong body"
rewind fail2 "$T/mirror/install.sh"
f=$(ls $T/mirror/assets/c1-*.tar.zst | head -1); ls $T/mirror/assets/c1-* | wc -l >/dev/null
for f in $(sed -n 's/.*"name": "\(\(c[0-9]\|core\)-[0-9a-f]*.tar.zst\)".*/\1/p' $T/mirror/latest.json); do cp "$T/mirror/assets/$f" "$T/mirror/assets/$f.good"; head -c 1000 /dev/urandom > "$T/mirror/assets/$f"; done
launch fail2
check "damaged part: the installed v0.1.0 still starts" 'waitfor "[ \$(starts fail2) -ge 1 ]" 60'
check "damaged part (nothing replaced yet): no update.mixed marker" '[ ! -e $T/fail2/.local/share/do27-alpha/update.mixed ]'
check "damaged part: failure said plainly" 'grep -Eq "damaged|The update (failed|stopped)" $T/logs/fail2.stub $T/logs/fail2.out'
for f in $(sed -n 's/.*"name": "\(\(c[0-9]\|core\)-[0-9a-f]*.tar.zst\)".*/\1/p' $T/mirror/latest.json); do mv -f "$T/mirror/assets/$f.good" "$T/mirror/assets/$f"; done

fi
if want T7; then
echo "== T7: update stopped after some parts were replaced (two builds mixed): the game is NOT started; it carries on at the next start"
rewind mix "$T/mirror/install.sh"
launch mix
waitfor 'grep -q "Part 3 of 5" $T/mix/.local/share/do27-alpha/update.log 2>/dev/null' 90
sleep 2
pkill -9 -f "$T/mix/.local/bin/do27"; pkill -9 -f "bash $T/mix/.local/share/do27-alpha/.install"; pkill -9 -f "curl.*127.0.0.1:$PORT"
sleep 1
check "mixed: marker update.mixed exists (v0.1.1)" '[ "$(cat $T/mix/.local/share/do27-alpha/update.mixed 2>/dev/null)" = v0.1.1 ]'
pkill -f "serve.py $T/mirror"; sleep 0.5       # the next start cannot finish the update
launch mix
sleep 8
check "mixed: the game was not started" '[ "$(starts mix)" = 0 ]'
check "mixed: said plainly" 'grep -q "The update to v0.1.1 did not finish. Start Direct Order 27 again to continue it (it picks up where it stopped)." $T/logs/mix.stub $T/logs/mix.out'
check "mixed: VERSION still v0.1.0" '[ "$(ver mix)" = v0.1.0 ]'
setsid -f python3 -I "$HERE/serve.py" "$T/mirror" "$PORT" "$RATE" >>"$T/logs/server.log" 2>&1; sleep 1
launch mix
check "mixed: next start (server back) finishes and starts the game" 'waitfor "[ \$(starts mix) -ge 1 ]" 90 && [ "$(ver mix)" = v0.1.1 ]'
check "mixed: marker cleared" '[ ! -e $T/mix/.local/share/do27-alpha/update.mixed ]'
check "mixed: exactly one game" 'sleep 2; [ "$(starts mix)" = 1 ]'
echo "-- mixed, failure inside install.sh (last part damaged): game not started either"
rewind mix2 "$T/mirror/install.sh"
last=$(sed -n 's/.*"name": "\(c[0-9]-[0-9a-f]*.tar.zst\)".*/\1/p' $T/mirror/latest.json | tail -1)
cp "$T/mirror/assets/$last" "$T/mirror/assets/$last.good"; head -c 1000 /dev/urandom > "$T/mirror/assets/$last"
launch mix2
sleep 25
check "mixed2: game not started after a failure past the first replaced part" '[ "$(starts mix2)" = 0 ] && [ -f $T/mix2/.local/share/do27-alpha/update.mixed ]'
check "mixed2: said plainly" 'grep -q "did not finish. Start Direct Order 27 again" $T/logs/mix2.stub $T/logs/mix2.out'
mv -f "$T/mirror/assets/$last.good" "$T/mirror/assets/$last"
launch mix2
check "mixed2: after the part is fixed the next start finishes and starts" 'waitfor "[ \$(starts mix2) -ge 1 ]" 90 && [ "$(ver mix2)" = v0.1.1 ]'
fi
if want T6; then
  echo "== T6: no zenity / no display: notifications with a replace id; and a real terminal: the plain text"
  rewind six "$T/mirror/install.sh"
  launch six DISPLAY= PATH=$T/stubs2:/usr/bin:/bin
  check "notify: game started" 'waitfor "[ \$(starts six) -ge 1 ]" 90'
  check "notify: per-part notifications with the replace hint" 'grep -q "^notify -a Direct Order 27 -h string:x-canonical-private-synchronous:do27-update Direct Order 27 Updating to v0.1.1: part" $T/logs/six.stub'
  check "notify: done notice" 'grep -q "Update done, starting Direct Order 27" $T/logs/six.stub'
  rewind tty "$T/mirror/install.sh"
  script -qec "env HOME=$T/tty XDG_CACHE_HOME=$T/tty/.cache XDG_CONFIG_HOME=$T/tty/.config PATH=$T/stubs:$PATH STUBLOG=$T/logs/tty.stub DISPLAY=:99 $T/tty/.local/bin/do27" /dev/null </dev/null >"$T/logs/tty.out" 2>&1
  check "terminal: game started" '[ "$(starts tty)" = 1 ]'
  check "terminal: curl progress bar and part lines kept" 'grep -q "Part 1 of 5" $T/logs/tty.out && grep -q "####" $T/logs/tty.out'
  check "terminal: no zenity window" '! grep -q "^zenity" $T/logs/tty.stub 2>/dev/null'
fi

if [ -n "$OLD" ] && want T5; then
  echo "== T5: a player whose do27 command came from the OLD installer"
  new_home old
  # the old installer is served as the mirror's install.sh only for the initial install
  cp "$OLD" "$T/mirror/install.sh"
  python3 -I "$HERE/mkmirror.py" "$T/mirror" "$M" publish v0.1.0 >/dev/null
  install_as old "$T/mirror/install.sh"
  cp "$WT/install.sh" "$T/mirror/install.sh"
  python3 -I "$HERE/mkmirror.py" "$T/mirror" "$M" publish v0.1.1 >/dev/null
  check "old wrapper in place" '! grep -q "wrapper 2" $T/old/.local/bin/do27 && grep -q DO27_AUTOUPDATE $T/old/.local/bin/do27'
  : > "$T/mirror/requests.log"
  launch old
  check "old wrapper: update done and game started" 'waitfor "[ \$(starts old) -ge 1 ]" 90'
  check "old wrapper: VERSION v0.1.1" '[ "$(ver old)" = v0.1.1 ]'
  check "old wrapper: progress window + done notice" 'grep -q "progress: # Updating to v0.1.1: part" $T/logs/old.stub && grep -q "Update done, starting" $T/logs/old.stub'
  echo "-- old wrapper double click"
  new_home old2; cp "$OLD" "$T/mirror/install.sh"
  python3 -I "$HERE/mkmirror.py" "$T/mirror" "$M" publish v0.1.0 >/dev/null
  install_as old2 "$T/mirror/install.sh"
  cp "$WT/install.sh" "$T/mirror/install.sh"
  python3 -I "$HERE/mkmirror.py" "$T/mirror" "$M" publish v0.1.1 >/dev/null
  launch old2
  waitfor 'grep -q "Part 2 of 5" $T/old2/.local/share/do27-alpha/update.log 2>/dev/null' 90
  launch old2
  sleep 3
  check "old wrapper double click: Already updating" 'grep -Eq "Already updating \(part [0-9] of 5\)" $T/logs/old2.out $T/logs/old2.stub'
  check "old wrapper double click: no game while updating" '[ "$(starts old2)" = 0 ]'
  check "old wrapper double click: first update still finishes with one game" 'waitfor "[ \$(starts old2) -ge 1 ]" 90 && sleep 2 && [ "$(starts old2)" = 1 ] && [ "$(ver old2)" = v0.1.1 ]'
fi

pkill -f "serve.py $T/mirror" 2>/dev/null
check "the real HOME install was not touched" '[ "$(real_stamp)" = "$stamp0" ]'
echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" = 0 ]
