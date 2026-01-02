cask "typing-stats" do
  version "0.0.3"
  sha256 "5de3b4d64e0937c1ddd358d8ea4e13b68f2d27079eeb229d672492e9564b15d0"

  url "https://github.com/rauchg/typing-stats/releases/download/v#{version}/TypingStats.zip"
  name "Typing Stats"
  desc "Track your daily keystroke statistics"
  homepage "https://github.com/rauchg/typing-stats"

  app "TypingStats.app"

  postflight do
    system "xattr", "-cr", "#{appdir}/TypingStats.app"
  end

  zap trash: [
    "~/Library/Application Support/TypingStats",
    "~/Library/Preferences/com.typing-stats.app.plist",
  ]
end
