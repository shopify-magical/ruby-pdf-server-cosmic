require 'net/http'
require 'json'
require 'base64'

uri = URI('http://localhost:4567/pdf/template/cheese_ritual')
data = {
  practitioner: 'The Moist Master',
  cheese_type: 'Cave-Aged Roquefort',
  ritual_date: '2026-01-26',
  incantation: 'Deep in the cavern where silence resides, \nThe moisture of ages in darkness it hides. \nLet the rind soften, let the mold bloom, \nWithin the slick walls of this shadowy room.',
  theme: 'damp_cave',
  aging_humidity: '92%',
  watermark: 'MOIST'
}

puts "🌑 Summoning the Moist Manifest..."

response = Net::HTTP.post(uri, data.to_json, "Content-Type" => "application/json")

if response.is_a?(Net::HTTPSuccess)
  result = JSON.parse(response.body)
  if result['success']
    pdf_data = Base64.strict_decode64(result['pdf_base64'])
    File.open('moist_manifest.pdf', 'wb') { |f| f.write(pdf_data) }
    puts "🌑 Moist Manifest successfully materialized as 'moist_manifest.pdf'."
  else
    puts "🏮 Manifestation failed: #{result['error']}"
  end
else
  puts "🏮 Server unreachable: #{response.code}"
end
