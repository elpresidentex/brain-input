#!/bin/bash
# Generates speech fixtures with `say` (16 kHz mono WAV, the format whisper expects).
set -euo pipefail
cd "$(dirname "$0")/../Tests/Fixtures/audio"
mk() { # name voice text
  [ -f "$1.wav" ] || say -v "$2" -o "$1.wav" --data-format=LEI16@16000 "$3"
}
EN="Eddy (English (US))"; EN2="Flo (English (US))"; DE="Anna"
mk en_short "$EN" "Please send me the report by Friday afternoon."
mk de_short "$DE" "Kannst du mir bitte den Bericht bis Freitag schicken?"
mk en_long "$EN" "I looked at the numbers again this morning. Revenue is up eight percent compared to last quarter, but support tickets doubled. I think we should hire one more person for the support team before we start the next marketing campaign. Let me know what you think."
mk de_long "$DE" "Ich habe mir die Zahlen heute Morgen noch einmal angesehen. Der Umsatz ist um acht Prozent gestiegen, aber die Zahl der Support-Anfragen hat sich verdoppelt. Wir sollten jemanden einstellen, bevor wir die nächste Kampagne starten."
mk en_terms "$EN" "Ask Katarzyna to deploy the Kubernetes cluster with Terraform."
mk meeting_me_1 "$EN" "Hi Thomas, thanks for joining. Let's decide on the launch date today."
mk meeting_them_1 "$EN2" "Sounds good. I think we should launch on the first of December."
mk meeting_me_2 "$EN" "Agreed. I will prepare the announcement by next Wednesday."
ls -la
