# voice-list.sh - print every Vox command available on macOS.

cat <<'EOF'
Vox - voice control for Claude Code (macOS). Commands:

  SINGLE CLI
  /vox:listen        start hands-free voice input (this CLI)
  /vox:speak on|off  Claude reads replies aloud
  /vox:hush          stop talking now, keep listening
  /vox:stop          stop the listener + silence speech

  TUNING
  /vox:duplex full   headphones: always listen + barge-in
  /vox:duplex half   speakers: deaf while Claude speaks (default)
  /vox:aim           re-aim voice at another terminal (5s grab)
  /vox:status        state + recent log
  /vox:check         verify mic/speech permission + on-device model
  /vox:test          speak a test sentence, list voices
  /vox:list          this list

Flow: say "hey claude" -> chime -> speak -> stop talking. It sends on your
pause. Cut a long reply with /vox:hush. (The multi-CLI hub is not on macOS yet.)
EOF
