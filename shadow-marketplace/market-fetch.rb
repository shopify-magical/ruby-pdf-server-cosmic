#!/usr/bin/env ruby
require 'net/http'
require 'json'

# Colors for the shadow aesthetic
def colorize(text, color_code)
  "\e[#{color_code}m#{text}\e[0m"
end

BLUE = 34
CYAN = 36
RED = 31
GRAY = 90
GOLD = 33

begin
  uri = URI('http://localhost:4568/api/metadata')
  response = Net::HTTP.get(uri)
  data = JSON.parse(response)

  puts colorize("        .---.        ", GRAY)
  puts colorize("       /     \\       ", GRAY) + colorize("  SHADOW MARKETPLACE", RED)
  puts colorize("      |  (O)  |      ", GRAY) + colorize("  ------------------", GRAY)
  puts colorize("   --- \\     / ---   ", GRAY) + colorize("  Status:    ", CYAN) + "Operational"
  puts colorize("    \\   '---'   /    ", GRAY) + colorize("  Port:      ", CYAN) + "4568"
  puts colorize("     \\         /     ", GRAY) + colorize("  Vault:     ", CYAN) + "#{data['total_assets']} Assets"
  puts colorize("      '-------'      ", GRAY) + colorize("  Range:     ", CYAN) + "$#{data['price_range']['min']} - $#{data['price_range']['max']}"
  puts colorize("                     ", GRAY) + colorize("  Categories:", CYAN) + " #{data['categories'].join(', ')}"
  puts ""

rescue => e
  puts colorize("  [!] Error: Shadow Marketplace is offline.", RED)
end
