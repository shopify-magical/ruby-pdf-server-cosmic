require 'net/http'
require 'json'
require 'base64'

uri = URI('http://localhost:4567/pdf/template/seafood_manifest')

# Data for อาหารทะเลแห้ง (Dried Seafood) and Processed Food
inventory = [
  { 'name' => 'Dried Squid (Premium)', 'weight' => 500, 'price' => 25, 'margin' => '20%' },
  { 'name' => 'Dried Shrimp (Grade A)', 'weight' => 200, 'price' => 40, 'margin' => '25%' },
  { 'name' => 'Fish Maw (Golden)', 'weight' => 50, 'price' => 150, 'margin' => '30%' },
  { 'name' => 'Dried Scallops', 'weight' => 100, 'price' => 80, 'margin' => '22%' },
  { 'name' => 'Crispy Processed Fish', 'weight' => 300, 'price' => 15, 'margin' => '18%' }
]

total_value = inventory.sum { |i| i['weight'] * i['price'] }

data = {
  trader_id: 'TRADER-SEAFOOD-88',
  market_sector: 'DRIED SEAFOOD & PROCESSED FOOD / อาหารทะเลแห้ง',
  inventory: inventory,
  total_value: total_value.to_f,
  theme: 'classic',
  watermark: 'PROFITS'
}

puts "🌑 Summoning the Profitable Manifest..."

response = Net::HTTP.post(uri, data.to_json, "Content-Type" => "application/json")

if response.is_a?(Net::HTTPSuccess)
  result = JSON.parse(response.body)
  if result['success']
    pdf_data = Base64.strict_decode64(result['pdf_base64'])
    File.open('seafood_profits_manifest.pdf', 'wb') { |f| f.write(pdf_data) }
    puts "🌑 Profitable Manifest materialized as 'seafood_profits_manifest.pdf'."
    puts "🌑 Total Manifest Value: $#{total_value}"
  else
    puts "🏮 Synthesis failed: #{result['error']}"
  end
else
  puts "🏮 Server unreachable: #{response.code}"
end
