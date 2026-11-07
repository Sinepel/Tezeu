# Formule Homebrew de Tézeu. Mise à jour par la GitHub Action à chaque release publiée.
# Installation : brew tap sinepel/tezeu https://github.com/Sinepel/Tezeu
#                brew install --cask tezeu
cask "tezeu" do
  version "0.1.0"
  sha256 "58cb44b22b0c52821a558f9c0bbd3650957d6fa136ade0aaba745384ea1fb5e6"

  url "https://github.com/Sinepel/Tezeu/releases/download/v#{version}/Tezeu-v#{version}-macos-arm64.zip"
  name "Tézeu"
  desc "Push-to-talk dictation, 100% offline (whisper.cpp)"
  homepage "https://github.com/Sinepel/Tezeu"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Tezeu.app"

  zap trash: [
    "~/Library/Application Support/Tezeu",
    "~/Library/Preferences/local.tezeu.app.plist",
  ]

  caveats <<~EOS
    Tézeu is not notarized by Apple (no paid developer account).
    On first launch, macOS blocks it: open System Settings > Privacy & Security
    and click "Open Anyway".

    After each update, grant Accessibility again: uncheck then re-check Tezeu in
    System Settings > Privacy & Security > Accessibility.
  EOS
end
