require 'sinatra'
require 'json'

# Enable CORS manually to avoid extra dependencies
before do
  content_type :json
  headers 'Access-Control-Allow-Origin' => '*',
          'Access-Control-Allow-Methods' => ['GET', 'POST', 'OPTIONS'],
          'Access-Control-Allow-Headers' => 'Content-Type'
end

options "*" do
  response.headers["Allow"] = "GET, POST, OPTIONS"
  response.headers["Access-Control-Allow-Headers"] = "X-Requested-With, X-HTTP-Method-Override, Content-Type, Cache-Control, Accept"
  response.headers["Access-Control-Allow-Origin"] = "*"
  200
end

set :port, 4568 # Different port from the PDF server
set :bind, '0.0.0.0'

# Load the inventory of shadowy assets
INVENTORY_FILE = File.join(__dir__, 'data', 'inventory.json')

def load_inventory
  JSON.parse(File.read(INVENTORY_FILE))
end

# Log helper
def log_market(message)
  puts "[#{Time.now.strftime('%H:%M:%S')}] ⚖️ MARKET: #{message}"
end

get '/' do
  content_type :json
  { status: 'Marketplace operational', vault: 'Shadow Assets' }.to_json
end

# Main filtering endpoint for the marketplace app
get '/api/products' do
  content_type :json
  
  products = load_inventory
  
  # Filtering logic
  category = params['category']
  sub_category = params['sub_category']
  min_price = params['min_price']&.to_f
  max_price = params['max_price']&.to_f
  min_stock = params['min_stock']&.to_i
  search = params['search']&.downcase

  filtered = products.select do |p|
    match = true
    
    match &&= (p['category'] == category) if category
    match &&= (p['sub_category'] == sub_category) if sub_category
    match &&= (p['market_price_usd'] >= min_price) if min_price
    match &&= (p['market_price_usd'] <= max_price) if max_price
    match &&= (p['stock_level'] >= min_stock) if min_stock
    
    if search
      match &&= (p['name_en'].downcase.include?(search) || 
                 p['name_th'].include?(search) || 
                 p['description'].downcase.include?(search))
    end
    
    match
  end

  log_market("Filtered #{filtered.size} items for search: '#{search || 'none'}'")
  filtered.to_json
end

# Metadata endpoint for filters (categories, etc.)
get '/api/metadata' do
  content_type :json
  products = load_inventory
  
  {
    categories: products.map { |p| p['category'] }.uniq,
    sub_categories: products.map { |p| p['sub_category'] }.uniq,
    price_range: {
      min: products.map { |p| p['market_price_usd'] }.min,
      max: products.map { |p| p['market_price_usd'] }.max
    },
    total_assets: products.size
  }.to_json
end

log_market("Shadow Marketplace initialized on port 4568")
