require 'net/http'
require 'json'
require 'base64'

uri = URI('http://localhost:4567/pdf/template/cheese_ritual')
data = {
  practitioner: 'Master of Shadowy Aesthetics',
  cheese_type: 'Stilton of Eternal Night',
  ritual_date: '2026-01-26',
  incantation: 'By the darkness in the core, \nBy the mold that came before, \nLet the cheese of shadows rise, \nHidden from the mortal eyes.',
  theme: 'oblivion',
  watermark: 'DARK CHEESE'
}

puts "🌑 Initiating Shadow Manifestation..."

response = Net::HTTP.post(uri, data.to_json, "Content-Type" => "application/json")

if response.is_a?(Net::HTTPSuccess)
  result = JSON.parse(response.body)
  if result['success']
    pdf_data = Base64.strict_decode64(result['pdf_base64'])
    File.open('shadow_manifest.pdf', 'wb') { |f| f.write(pdf_data) }
    puts "🌑 Shadow Manifest successfully materialized as 'shadow_manifest.pdf'."
  else
    puts "🏮 Manifestation failed: #{result['error']}"
  end
else
  puts "🏮 Server unreachable: #{response.code}"
end
