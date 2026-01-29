require 'sinatra'
require 'json'
require 'prawn'
require 'prawn/table'
require 'dotenv/load'
require 'base64'
require 'stringio'
require 'digest'
require 'rqrcode'
require 'zip'

# Cosmic Cache & Logs Initialization
# Cosmic Cache Architecture
class CosmicCache
  def initialize(max_size = 100, ttl = 3600)
    @max_size = max_size
    @ttl = ttl
    @store = {}
    @access_order = []
    @lock = Mutex.new
    start_eviction_engine
  end

  def [](key)
    @lock.synchronize do
      if @store.key?(key)
        if Time.now > @store[key][:expires_at]
          delete_key(key)
          nil
        else
          @access_order.delete(key)
          @access_order << key
          @store[key][:data]
        end
      end
    end
  end

  def []=(key, value)
    @lock.synchronize do
      delete_key(key) if @store.key?(key)
      
      if @access_order.size >= @max_size
        oldest = @access_order.shift
        @store.delete(oldest)
      end
      
      @store[key] = {
        data: value,
        expires_at: Time.now + @ttl
      }
      @access_order << key
    end
  end

  def key?(key)
    @lock.synchronize do
      @store.key?(key) && Time.now <= @store[key][:expires_at]
    end
  end

  def size
    @lock.synchronize { @store.size }
  end

  private

  def start_eviction_engine
    Thread.new do
      loop do
        sleep 60 # Check every minute
        @lock.synchronize do
          expired_keys = @store.select { |_, v| Time.now > v[:expires_at] }.keys
          expired_keys.each { |k| delete_key(k) }
        end
      end
    end
  end

  def delete_key(key)
    @store.delete(key)
    @access_order.delete(key)
  end
end

CACHE = CosmicCache.new(100, 3600) # 100 items, 1 hour TTL
LOGS = []
MAX_LOG_SIZE = 50
$global_cache_hits = 0

MAX_THREADS = 16 # Optimal for high-speed synthesis
REQUEST_COUNT = { 
  total: 0, 
  start_time: Time.now,
  history: [] # Sliding window for throughput
}

def log_event(level, message)
  emoji = case level.to_s.downcase
          when 'info' then '🌑'
          when 'error' then '🏮'
          when 'debug' then '🕯️'
          else '🌑'
          end
  entry = "[#{Time.now.strftime('%H:%M:%S')}] #{emoji} #{level.upcase}: #{message}"
  LOGS.unshift(entry)
  LOGS.pop if LOGS.size > MAX_LOG_SIZE
  puts entry # Also output to terminal
end

# Middleware to track throughput and latency
before do
  @start_time = Time.now
  REQUEST_COUNT[:total] += 1
  REQUEST_COUNT[:history] << Time.now
  # Keep only last 60 seconds for sliding window
  REQUEST_COUNT[:history].delete_if { |t| t < Time.now - 60 }
  
  response.headers['Access-Control-Allow-Origin'] = '*'
  response.headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS'
  response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
end

after do
  duration = (Time.now - @start_time) * 1000 # ms
  @last_latency = duration.round(2)
end

log_event('info', 'Cosmic Node initialized')
log_event('info', 'PDF Engine ready')
log_event('debug', 'Cache layer operational')
log_event('info', 'Metrics collection started')

configure do
  set :port, ENV['PORT'] || 4567
  set :bind, '0.0.0.0'
  set :public_folder, File.dirname(__FILE__) + '/public'
  set :views, File.dirname(__FILE__) + '/views'
  enable :cross_origin
end

options '*' do
  200
end

get '/' do
  content_type :json
  {
    service: 'Ruby++ PDF Server',
    version: '2.0.0',
    status: 'running',
    ruby_version: RUBY_VERSION,
    endpoints: {
      'POST /pdf/generate' => 'Generate PDF from data',
      'POST /pdf/from-html' => 'Generate PDF from HTML',
      'POST /pdf/from-url' => 'Generate PDF from URL',
      'GET /pdf/templates' => 'List available templates',
      'POST /pdf/merge' => 'Merge multiple PDFs',
      'POST /pdf/split' => 'Split PDF pages',
      'POST /pdf/watermark' => 'Add watermark to PDF',
      'POST /pdf/encrypt' => 'Encrypt PDF',
      'POST /pdf/batch' => 'Batch generate multiple PDFs',
      'POST /pdf/batch-zip' => 'Batch generate PDFs and return as ZIP archive',
      'GET /health' => 'Health check',
      'GET /metrics' => 'System metrics'
    }
  }.to_json
end

post '/pdf/batch-zip' do
  content_type 'application/zip'
  
  begin
    request.body.rewind
    data = JSON.parse(request.body.read)
    requests = data['requests'] || []
    
    log_event('info', "ZIP Batch synthesis requested: #{requests.length} documents")
    
    temp_zip = Tempfile.new(['batch', '.zip'])
    
    Zip::File.open(temp_zip.path, Zip::File::CREATE) do |zipfile|
      # Use parallel processing for PDF generation
      results_mutex = Mutex.new
      
      # Limit concurrency to avoid resource exhaustion
      requests.each_slice(MAX_THREADS) do |slice|
        threads = slice.each_with_index.map do |req, index|
          Thread.new do
            begin
              pdf = Prawn::Document.new(page_size: req['page_size'] || 'LETTER')
              apply_cosmic_theme(pdf, req['theme'] || 'classic')
              
              pdf.text req['title'] || "Archive Doc", size: 20, style: :bold
              pdf.move_down 10
              pdf.text req['content'] || "Payload content"
              
              pdf_data = pdf.render
              filename = req['filename'] || "doc_#{SecureRandom.hex(4)}.pdf"
              
              results_mutex.synchronize do
                zipfile.get_output_stream(filename) { |os| os.write(pdf_data) }
              end
            rescue => e
              log_event('error', "ZIP Batch thread error: #{e.message}")
            end
          end
        end
        threads.each(&:join)
      end
    end
    
    send_file temp_zip.path, type: 'application/zip', filename: "batch_#{Time.now.to_i}.zip"
  rescue => e
    content_type :json
    { success: false, error: e.message }.to_json
  end
end

get '/health' do
  content_type :json
  {
    status: 'healthy',
    timestamp: Time.now.iso8601,
    version: '2.0.0',
    ruby_version: RUBY_VERSION,
    memory_usage: `ps -o rss= -p #{Process.pid}`.strip.to_i
  }.to_json
end

get '/metrics' do
  content_type :json
  
    # Accurate sliding window throughput (last 60s)
    REQUEST_COUNT[:history].delete_if { |t| t < Time.now - 60 }
    window_size = REQUEST_COUNT[:history].size
    throughput_60s = (window_size / 60.0).round(4)
    
    uptime = `ps -o etime= -p #{Process.pid}`.strip
    cpu_usage = `ps -o %cpu= -p #{Process.pid}`.strip
    memory_mb = (`ps -o rss= -p #{Process.pid}`.strip.to_f / 1024).round(2)
    load_avg = `sysctl -n vm.loadavg`.split[1..3].join(' ') rescue 'N/A'
    
    # Collect all signatures from cache for verification protocol
    signatures = {}
    CACHE.instance_variable_get(:@store).each do |key, entry|
      if entry[:data] && entry[:data][:signature]
        signatures[entry[:data][:signature]] = {
          cache_key: key,
          filename: entry[:data][:filename],
          file_hash: entry[:data][:file_hash],
          created_at: entry[:expires_at] - 3600 # Approx creation time
        }
      end
    end

    # Calculate Shadow Level & Humidity
    shadow_level = ((REQUEST_COUNT[:total] * 0.1) + (CACHE.size * 0.5) + rand(1..10)).round(2)
    humidity = (70 + rand(0..25) + (CACHE.size * 0.2)).round(2) # Ideal for cheese aging
    
    shadow_status = case shadow_level
                    when 0..20 then 'Dim'
                    when 20..50 then 'Deepening'
                    when 50..80 then 'Abyssal'
                    else 'Absolute Oblivion'
                    end

    {
      uptime: uptime,
      cpu_usage: "#{cpu_usage}%",
      memory_usage: "#{memory_mb} MB",
      load_avg: load_avg,
      threads: Thread.list.count,
      ruby_engine: RUBY_ENGINE,
      platform: RUBY_PLATFORM,
      cache_hits: $global_cache_hits,
      cache_size: CACHE.size,
      throughput: "#{throughput_60s} req/s (60s window)",
      total_requests: REQUEST_COUNT[:total],
      last_latency_ms: @last_latency || 0,
      shadow_metrics: {
        level: shadow_level,
        status: shadow_status,
        humidity: "#{humidity}%",
        ritual_ready: CACHE.size > 5
      },
      signatures: signatures
    }.to_json
  end

get '/logs' do
  content_type :json
  { logs: LOGS }.to_json
end

post '/pdf/batch' do
  content_type :json
  
  begin
    request.body.rewind
    data = JSON.parse(request.body.read)
    requests = data['requests'] || []
    
    log_event('info', "Batch synthesis requested: #{requests.length} documents")
    
    return { success: false, error: 'No requests provided' }.to_json if requests.empty?
    
    results = []
    results_mutex = Mutex.new
    
    # Process each request in the batch using Parallel Threads
    threads = requests.each_with_index.map do |req, index|
      Thread.new do
        begin
          # Simplified version of generation for batch
          pdf = Prawn::Document.new(page_size: req['page_size'] || 'LETTER')
          
          # Apply Theme
          apply_cosmic_theme(pdf, req['theme'] || 'classic')
          
          pdf.text req['title'] || "Batch Document #{index + 1}", size: 20, style: :bold
          pdf.move_down 10
          pdf.text req['content'] || "Payload content for index #{index}"
          
          pdf_data = pdf.render
          
          results_mutex.synchronize do
            results << {
               filename: req['filename'] || "batch_doc_#{index + 1}.pdf",
               pdf_base64: Base64.strict_encode64(pdf_data)
             }
          end
        rescue => e
          log_event('error', "Batch thread error at index #{index}: #{e.message}")
        end
      end
    end
    
    threads.each(&:join)
    
    {
      success: true,
      batch_id: SecureRandom.uuid,
      count: results.length,
      documents: results
    }.to_json
    
  rescue => e
    { success: false, error: e.message }.to_json
  end
end

post '/pdf/generate' do
  content_type :json
  
  begin
    request.body.rewind
    data = JSON.parse(request.body.read)
    
    log_event('info', "PDF synthesis requested: #{data['title'] || 'untitled'}")
    
    # Generate Standardized Cache Key (Sorted for stability)
    # Optimization: Remove volatile fields and normalize data types for higher hit rates
    standardized_data = data.dup
    ['filename', 'webhook_url', 'timestamp', 'request_id'].each { |k| standardized_data.delete(k) }
    
    # Normalize values (strings to symbols/strings, float to int where applicable)
    normalized_data = {}
    standardized_data.sort.to_h.each do |k, v|
      normalized_data[k] = v.is_a?(Numeric) ? v.to_f : v
    end
    
    cache_key = Digest::SHA256.hexdigest(normalized_data.to_json)
    log_event('debug', "Standardized Cache Key: #{cache_key[0..15]}...")
    
    if CACHE.key?(cache_key)
      log_event('debug', "Cache hit for #{cache_key[0..7]}")
      $global_cache_hits += 1
      # Update latency for cache hit
      @last_latency = ((Time.now - @start_time) * 1000).round(2)
      return CACHE[cache_key].to_json
    end
    
    pdf = Prawn::Document.new(
      page_size: data['page_size'] || 'LETTER',
      margin: data['margin'] || 40,
      info: {
        Title: data['title'] || "Cosmic Document",
        Author: "Ruby++ PDF Engine",
        Creator: "Ruby++",
        CreationDate: Time.now
      }
    )

    # Apply Encryption if password provided
    if data['password'] && !data['password'].empty?
      pdf.encrypt_document(
        user_password: data['password'],
        owner_password: data['owner_password'] || data['password'],
        permissions: { print: true, modify: false, copy: true }
      )
    end

    # Apply Visual Theme
    apply_cosmic_theme(pdf, data['theme'] || 'classic')

    # Add title
    if data['title']
      pdf.text data['title'], 
        size: data['title_size'] || 24, 
        style: :bold, 
        align: :center
      pdf.move_down 20
    end

    # Add content
    if data['content']
      pdf.text data['content'], 
        size: data['content_size'] || 12,
        align: data['align'] || :left
    end

    # Add table if provided
    if data['table']
      pdf.move_down 20
      pdf.table(data['table']['data'], 
        header: data['table']['header'] || true,
        width: pdf.bounds.width
      ) do
        row(0).font_style = :bold if data['table']['header']
      end
    end

    # Add image if provided
    if data['image']
      pdf.move_down 20
      if data['image'].start_with?('data:image')
        # Base64 image
        image_data = Base64.decode64(data['image'].split(',')[1])
        pdf.image StringIO.new(image_data), 
          width: data['image_width'] || 300,
          position: :center
      else
        # URL or file path
        begin
          pdf.image data['image'], 
            width: data['image_width'] || 300,
            position: :center
        rescue => e
          pdf.text "Image could not be loaded: #{e.message}", color: 'FF0000'
        end
      end
    end

    # Add QR Code if provided
    if data['qrcode']
      pdf.move_down 20
      begin
        qrcode = RQRCode::QRCode.new(data['qrcode'])
        png = qrcode.as_png(
          bit_depth: 1,
          border_modules: 4,
          color_mode: ChunkyPNG::COLOR_GRAYSCALE,
          color: 'black',
          file: nil,
          fill: 'white',
          module_px_size: 6,
          resize_exactly_to: false,
          resize_gte_to: false,
          size: 120
        )
        pdf.image StringIO.new(png.to_s), 
          width: data['qrcode_width'] || 100,
          position: data['qrcode_position']&.to_sym || :right
      rescue => e
        pdf.text "QR Generation Failed: #{e.message}", color: 'FF0000', size: 8
      end
    end

    # Add footer
    if data['footer']
      pdf.move_down 30
      pdf.text data['footer'], 
        size: 10, 
        align: :center, 
        color: '666666'
    end

    # Apply Watermark Protocol
    apply_cosmic_watermark(pdf, data['watermark'])

    # Generate PDF
    pdf_data = pdf.render
    
    # Store in Cosmic Cache
    CACHE[cache_key] = {
      success: true,
      pdf_base64: Base64.strict_encode64(pdf_data),
      filename: data['filename'] || "#{data['title'] || 'document'}.pdf",
      signature: (pdf.state.store.info.data[:Signature] rescue nil),
      file_hash: Digest::SHA256.hexdigest(pdf_data)
    }
    
    # Async Webhook Relay
    if data['webhook_url']
      Thread.new do
        begin
          log_event('info', "Relaying manifest to webhook: #{data['webhook_url']}")
          uri = URI(data['webhook_url'])
          Net::HTTP.post(uri, {
            event: 'pdf_generated',
            filename: data['filename'],
            timestamp: Time.now.to_i,
            cache_key: cache_key
          }.to_json, "Content-Type" => "application/json")
        rescue => e
          log_event('error', "Webhook relay failed: #{e.message}")
        end
      end
    end
    
    # Update global cache hits counter
    $global_cache_hits = ($global_cache_hits || 0)
    
    CACHE[cache_key].to_json

  rescue => e
    {
      success: false,
      error: e.message,
      backtrace: e.backtrace.first(5)
    }.to_json
  end
end

post '/pdf/from-html' do
  content_type :json
  
  begin
    request.body.rewind
    data = JSON.parse(request.body.read)
    
    log_event('info', "HTML-to-PDF synthesis requested")
    
    pdf = Prawn::Document.new(
      page_size: data['page_size'] || 'LETTER',
      margin: data['margin'] || 40
    )

    # Apply Theme
    apply_cosmic_theme(pdf, data['theme'] || 'classic')

    # Simple HTML to text conversion (basic implementation)
    html_content = data['html'] || ''
    
    # Remove HTML tags (basic)
    text_content = html_content
      .gsub(/<[^>]*>/, ' ')
      .gsub(/\s+/, ' ')
      .strip

    pdf.text text_content, size: 12

    pdf_data = pdf.render
    
    {
      success: true,
      pdf_base64: Base64.strict_encode64(pdf_data),
      filename: data['filename'] || 'html_document.pdf',
      pages: pdf.page_count,
      size: pdf_data.bytesize
    }.to_json

  rescue => e
    {
      success: false,
      error: e.message
    }.to_json
  end
end

post '/pdf/from-url' do
  content_type :json
  
  begin
    request.body.rewind
    data = JSON.parse(request.body.read)
    url = data['url']
    
    log_event('info', "URL-to-PDF synthesis requested: #{url}")
    
    return { success: false, error: 'No URL provided' }.to_json unless url

    # In a real cosmic-scale app, we'd use 'ferrum' or 'puppeteer'
    # For this high-speed protocol, we'll fetch and strip
    require 'open-uri'
    html_content = URI.open(url).read
    
    pdf = Prawn::Document.new(
      page_size: data['page_size'] || 'LETTER',
      margin: data['margin'] || 40
    )

    # Apply Theme
    apply_cosmic_theme(pdf, data['theme'] || 'classic')

    # Basic content extraction with UTF-8 Sanitization
    text_content = html_content
      .force_encoding('UTF-8')
      .encode('UTF-8', invalid: :replace, undef: :replace, replace: '?')
      .gsub(/<script.*?<\/script>/m, '')
      .gsub(/<style.*?<\/style>/m, '')
      .gsub(/<[^>]*>/, ' ')
      .gsub(/\s+/, ' ')
      .strip

    # Prawn default fonts only support WinAnsiEncoding. 
    # We must strip characters that will crash the generator.
    safe_text = text_content.chars.select { |c| c.bytes.all? { |b| b < 128 } }.join
    
    pdf.text "Source: #{url}", size: 8, color: '888888'
    pdf.move_down 20
    pdf.text safe_text, size: 10

    pdf_data = pdf.render
    
    {
      success: true,
      pdf_base64: Base64.strict_encode64(pdf_data),
      filename: data['filename'] || "url_#{Time.now.to_i}.pdf",
      url: url
    }.to_json

  rescue => e
    {
      success: false,
      error: e.message
    }.to_json
  end
end

post '/pdf/merge' do
  content_type :json
  
  begin
    request.body.rewind
    data = JSON.parse(request.body.read)
    
    pdfs = data['pdfs'] || []
    return { success: false, error: 'No PDFs provided' }.to_json if pdfs.empty?

    # Create new PDF
    merged_pdf = Prawn::Document.new

    pdfs.each do |pdf_data|
      if pdf_data.start_with?('data:application/pdf')
        # Decode base64 PDF
        pdf_content = Base64.decode64(pdf_data.split(',')[1])
        # Note: PDF merging would require additional gems like pdf-merger
        # For now, we'll create a placeholder
        merged_pdf.start_new_page
        merged_pdf.text "Merged PDF content here", align: :center
      end
    end

    result_pdf = merged_pdf.render
    
    {
      success: true,
      pdf_base64: Base64.encode64(result_pdf),
      filename: data['filename'] || 'merged_document.pdf',
      pages: merged_pdf.page_count,
      merged_count: pdfs.length
    }.to_json

  rescue => e
    {
      success: false,
      error: e.message
    }.to_json
  end
end

post '/pdf/watermark' do
  content_type :json
  
  begin
    request.body.rewind
    data = JSON.parse(request.body.read)
    
    pdf = Prawn::Document.new
    
    # Add watermark text
    if data['watermark']
      pdf.transparent(0.1) do
        pdf.rotate(45, origin: [200, 200]) do
          pdf.text data['watermark'], 
            size: 60, 
            style: :bold,
            align: :center
        end
      end
    end

    # Add content
    if data['content']
      pdf.text data['content'], size: 12
    end

    result_pdf = pdf.render
    
    {
      success: true,
      pdf_base64: Base64.encode64(result_pdf),
      filename: data['filename'] || 'watermarked_document.pdf',
      pages: pdf.page_count
    }.to_json

  rescue => e
    {
      success: false,
      error: e.message
    }.to_json
  end
end

get '/pdf/templates' do
  content_type :json
  
  templates = [
    {
      id: 'invoice',
      name: 'Fiscal Invoice',
      description: 'Standard business invoice with tax breakdown',
      fields: ['invoice_number', 'date', 'customer_name', 'items', 'total']
    },
    {
      id: 'report',
      name: 'Analytic Report',
      description: 'Multi-section document for data analysis',
      fields: ['title', 'author', 'date', 'sections']
    },
    {
      id: 'certificate',
      name: 'Merit Certificate',
      description: 'Formal recognition certificate',
      fields: ['recipient', 'course', 'date', 'issuer']
    },
    {
      id: 'resume',
      name: 'Resume Template',
      description: 'Professional resume/CV template',
      fields: ['name', 'contact_info', 'summary', 'experience', 'education', 'skills']
    },
    {
      id: 'badge',
      name: 'Digital Badge Protocol',
      description: 'Secure digital identity badge with embedded QR verification',
      fields: ['name', 'role', 'id_number', 'organization', 'verification_url']
    },
    {
      id: 'cheese_ritual',
      name: 'The Cheese Ritual',
      description: 'A dark decree for the master of shadowy aesthetics',
      fields: ['practitioner', 'cheese_type', 'ritual_date', 'incantation', 'aging_humidity']
    },
    {
      id: 'seafood_manifest',
      name: 'Seafood Commodity Manifest',
      description: 'High-value dried seafood and processed food trading data',
      fields: ['trader_id', 'market_sector', 'inventory', 'total_value']
    }
  ]
  
  {
    success: true,
    templates: templates,
    count: templates.length
  }.to_json
end

post '/pdf/template/:template_id' do
  content_type :json
  
  begin
    request.body.rewind
    data = JSON.parse(request.body.read) rescue {}
    template_id = params[:template_id]
    
    log_event('info', "Template synthesis requested: #{template_id}")
    
    # Generate Standardized Cache Key (Sorted for stability)
    standardized_data = data.reject { |k| ['filename', 'webhook_url'].include?(k) }
    cache_key = Digest::SHA256.hexdigest("#{template_id}-#{standardized_data.sort.to_h.to_json}")
    log_event('debug', "Template Cache Key (#{template_id}): #{cache_key[0..15]}...")
    
    if CACHE.key?(cache_key)
      log_event('debug', "Cache hit for template #{template_id}")
      $global_cache_hits += 1
      return CACHE[cache_key].to_json
    end
    
    pdf = case template_id
          when 'invoice'
            generate_invoice_pdf(data)
          when 'report'
            generate_report_pdf(data)
          when 'orbital_manifest'
            generate_orbital_manifest(data)
          when 'certificate'
            generate_certificate_pdf(data)
          when 'resume'
            generate_resume_pdf(data)
          when 'badge'
            generate_badge_pdf(data)
          when 'cheese_ritual'
            generate_cheese_ritual_pdf(data)
          when 'seafood_manifest'
            generate_seafood_manifest_pdf(data)
          else
            return { success: false, error: 'Template not found' }.to_json
          end

    pdf_data = pdf.render
    
    # Store in Cosmic Cache
    CACHE[cache_key] = {
      success: true,
      pdf_base64: Base64.strict_encode64(pdf_data),
      filename: data['filename'] || "#{template_id}_#{Time.now.to_i}.pdf",
      signature: (pdf.state.store.info.data[:Signature] rescue nil),
      file_hash: Digest::SHA256.hexdigest(pdf_data)
    }
    
    # Async Webhook Relay
    if data['webhook_url']
      Thread.new do
        begin
          log_event('info', "Relaying template manifest to webhook: #{data['webhook_url']}")
          uri = URI(data['webhook_url'])
          Net::HTTP.post(uri, {
            event: 'template_generated',
            template_id: template_id,
            filename: CACHE[cache_key][:filename],
            timestamp: Time.now.to_i
          }.to_json, "Content-Type" => "application/json")
        rescue => e
          log_event('error', "Webhook relay failed: #{e.message}")
        end
      end
    end
    
    CACHE[cache_key].to_json

  rescue => e
    {
      success: false,
      error: e.message
    }.to_json
  end
end

# --- Cosmic Helper Protocols ---

def apply_cosmic_theme(pdf, theme)
  case theme
  when 'dark_matter'
    pdf.canvas do
      pdf.fill_color '050a1f'
      pdf.fill_rectangle [0, pdf.bounds.height], pdf.bounds.width, pdf.bounds.height
    end
    pdf.font_size 12
    pdf.fill_color 'ffffff'
  when 'nebula'
    pdf.canvas do
      pdf.fill_color '1a1a2e'
      pdf.fill_rectangle [0, pdf.bounds.height], pdf.bounds.width, pdf.bounds.height
      pdf.fill_color '3366ff'
      pdf.fill_circle [0, 0], 200
      pdf.fill_color '7b4ba2'
      pdf.fill_circle [pdf.bounds.width, pdf.bounds.height], 300
    end
    pdf.fill_color 'ffffff'
  when 'blueprint'
    pdf.canvas do
      pdf.fill_color '003366'
      pdf.fill_rectangle [0, pdf.bounds.height], pdf.bounds.width, pdf.bounds.height
      pdf.stroke_color 'ffffff'
      pdf.line_width 0.1
      (0..pdf.bounds.width).step(20).each { |x| pdf.stroke_line [x, 0], [x, pdf.bounds.height] }
      (0..pdf.bounds.height).step(20).each { |y| pdf.stroke_line [0, y], [pdf.bounds.width, y] }
    end
    pdf.fill_color 'ffffff'
  when 'oblivion'
    pdf.canvas do
      pdf.fill_color '000000'
      pdf.fill_rectangle [0, pdf.bounds.height], pdf.bounds.width, pdf.bounds.height
      # Add subtle "shadow" noise or patterns
      pdf.fill_color '0a0a0a'
      100.times do
        x = rand(pdf.bounds.width)
        y = rand(pdf.bounds.height)
        size = rand(2..5)
        pdf.fill_circle [x, y], size
      end
    end
    pdf.font_size 12
    pdf.fill_color 'd4d4d4'
  when 'damp_cave'
    pdf.canvas do
      # Deep, wet blue-black background
      pdf.fill_color '0a0e14'
      pdf.fill_rectangle [0, pdf.bounds.height], pdf.bounds.width, pdf.bounds.height
      
      # Add "slick" highlights (simulating moisture on stone)
      pdf.stroke_color '1a2635'
      pdf.line_width 2
      20.times do
        x = rand(pdf.bounds.width)
        y = rand(pdf.bounds.height)
        len = rand(50..150)
        pdf.stroke_line [x, y], [x + 10, y - len]
      end
      
      # Add "droplets"
      pdf.fill_color '2a3b4c'
      50.times do
        pdf.fill_circle [rand(pdf.bounds.width), rand(pdf.bounds.height)], rand(1..3)
      end
    end
    pdf.fill_color 'aab9c8'
  end
end

def apply_cosmic_watermark(pdf, text)
  return unless text && !text.empty?
  
  pdf.canvas do
    pdf.fill_color '666666'
    pdf.transparent(0.1) do
      pdf.font_size 60
      # Create a diagonal watermark
      pdf.text_box text, 
        at: [0, pdf.bounds.height / 2], 
        width: pdf.bounds.width, 
        height: 200, 
        align: :center, 
        valign: :center, 
        rotate: 45
    end
  end
end

def apply_universal_qr(pdf, qr_data)
  return unless qr_data && !qr_data.empty?
  
  begin
    qrcode = RQRCode::QRCode.new(qr_data)
    png = qrcode.as_png(size: 80)
    temp_qr = Tempfile.new(['qr', '.png'])
    png.save(temp_qr.path)
    
    # Fixed position in bottom right corner for all templates
    pdf.image temp_qr.path, at: [pdf.bounds.width - 90, 80], width: 80
    temp_qr.close
    temp_qr.unlink
  rescue => e
    log_event('error', "Universal QR failure: #{e.message}")
  end
end

def apply_cosmic_signature(pdf)
  signature = "SIG-#{Digest::SHA256.hexdigest(Time.now.to_f.to_s)[0..12].upcase}"
  pdf.fill_color '888888'
  pdf.font_size(6) do
    pdf.text_box "COSMIC VERIFIED: #{signature}", 
      at: [0, 10], 
      width: pdf.bounds.width, 
      align: :center
  end
  signature
end

  def generate_invoice_pdf(data)
    pdf = Prawn::Document.new(page_size: 'A4', margin: 40)
    apply_cosmic_theme(pdf, data['theme'] || 'classic')
    
    pdf.text data['company_name'] || 'COSMIC NODE', size: 20, style: :bold
    pdf.text data['company_address'] || 'Sector 7, Nebula', size: 10
    pdf.move_down 20
    
    pdf.text "INVOICE", size: 32, style: :bold, align: :right
    pdf.text "##{data['invoice_number'] || 'INV-001'}", align: :right
    pdf.move_down 40
    
    pdf.text "BILL TO:", style: :bold
    pdf.text data['customer_name'] || 'Identity Unknown'
    pdf.move_down 20
    
    if data['items']
      items = [['Description', 'Qty', 'Price', 'Total']]
      data['items'].each do |item|
        items << [item['name'], item['quantity'], "$#{item['price']}", "$#{item['quantity'] * item['price']}"]
      end
      pdf.table(items, width: pdf.bounds.width) do
        row(0).font_style = :bold
        row(0).background_color = '3366ff'
        row(0).text_color = 'ffffff'
        columns(1..3).align = :right
      end
    end
    
    pdf.move_down 20
    pdf.text "TOTAL: $#{data['total']}", size: 20, style: :bold, align: :right

    apply_cosmic_watermark(pdf, data['watermark'])
    apply_universal_qr(pdf, data['qrcode'])
    
    # Apply Signature Protocol
    begin
      signature = apply_cosmic_signature(pdf)
      pdf.state.store.info.data[:Signature] = signature
    rescue => e
      log_event('error', "Metadata injection failure: #{e.message}")
    end
    pdf
  end

  def generate_seafood_manifest_pdf(data)
    pdf = Prawn::Document.new(page_size: 'A4', margin: 40)
    apply_cosmic_theme(pdf, data['theme'] || 'classic')

    # Sanitization for non-WinAnsi characters (Thai, etc.)
    safe_market = (data['market_sector'] || 'DRIED SEAFOOD').chars.select { |c| c.bytes.all? { |b| b < 128 } }.join
    
    pdf.text "SEAFOOD COMMODITY MANIFEST", size: 24, style: :bold, align: :center
    pdf.move_down 5
    pdf.text "MARKET SECTOR: #{safe_market}", align: :center, size: 10
    pdf.stroke_horizontal_rule
    pdf.move_down 20

    pdf.text "Trader ID: #{data['trader_id'] || 'T-8800-VOID'}", size: 12
    pdf.text "Timestamp: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}", size: 10
    pdf.move_down 20

    # Data Table Structure
    if data['inventory']
      table_data = [['Commodity', 'Weight (kg)', 'Unit Price', 'Total Value', 'Margin']]
      data['inventory'].each do |item|
        safe_name = (item['name'] || 'Unknown').chars.select { |c| c.bytes.all? { |b| b < 128 } }.join
        table_data << [
          safe_name,
          item['weight'] || 0,
          "$#{item['price'] || 0}",
          "$#{((item['weight'] || 0) * (item['price'] || 0)).round(2)}",
          "#{item['margin'] || '15%'}"
        ]
      end
      
      pdf.table(table_data, width: pdf.bounds.width) do
        row(0).font_style = :bold
        row(0).background_color = '222222'
        row(0).text_color = 'ffffff'
        columns(1..4).align = :right
        self.header = true
        self.row_colors = ['EEEEEE', 'FFFFFF']
      end
    else
      pdf.text "No inventory data provided for synthesis.", color: 'FF0000'
    end

    pdf.move_down 30
    pdf.text "TOTAL MANIFEST VALUE: $#{data['total_value'] || '0.00'}", size: 16, style: :bold, align: :right
    
    pdf.move_down 50
     pdf.text "Market Intelligence Report:", style: :bold
     pdf.text "Dried seafood remains a high-liquidity asset in the Eastern sectors. \nProcessed food items show a 22% increase in shadow market demand.", size: 10, leading: 3

    apply_cosmic_watermark(pdf, data['watermark'] || 'MARKET')
    apply_universal_qr(pdf, data['qrcode'] || "market-#{SecureRandom.hex(6)}")
    
    begin
      signature = apply_cosmic_signature(pdf)
      pdf.state.store.info.data[:Signature] = signature
    rescue => e
      log_event('error', "Metadata injection failure: #{e.message}")
    end
    pdf
  end

  def generate_cheese_ritual_pdf(data)
    pdf = Prawn::Document.new(page_size: 'A4', margin: 60)
    apply_cosmic_theme(pdf, data['theme'] || 'oblivion')

    pdf.move_down 50
    pdf.text "THE RITUAL OF THE DARK CHEESE", size: 36, style: :bold, align: :center, color: 'ff0000'
    pdf.move_down 20
    pdf.stroke_horizontal_rule
    pdf.move_down 40

    pdf.text "Let it be known in the halls of shadow that", size: 18, align: :center
    pdf.move_down 30
    pdf.text data['practitioner'] || 'THE SHADOW WALKER', size: 32, style: :bold, align: :center
    pdf.move_down 30
    pdf.text "has partaken in the sacred consumption of", size: 18, align: :center
    pdf.move_down 10
    pdf.text (data['cheese_type'] || 'GORGONZOLA OF THE ABYSS').upcase, size: 24, style: :bold, align: :center
    pdf.move_down 40

    pdf.text "The Incantation:", style: :italic, size: 14
    pdf.move_down 10
    pdf.text data['incantation'] || "Through the mold and through the rind, \nShadows seek what they shall find. \nCurd and whey in darkness blend, \nUntil the ritual reaches end.", align: :center, leading: 5
    pdf.move_down 60

    pdf.text "Performed on this dark day: #{data['ritual_date'] || Time.now.strftime('%Y-%m-%d')}", size: 12, align: :right
    pdf.text "Aging Humidity: #{data['aging_humidity'] || '85%'} (MOIST)", size: 10, align: :right, style: :italic

    apply_cosmic_watermark(pdf, data['watermark'] || 'VOID')
    apply_universal_qr(pdf, data['qrcode'] || "ritual-#{SecureRandom.hex(8)}")
    
    begin
      signature = apply_cosmic_signature(pdf)
      pdf.state.store.info.data[:Signature] = signature
    rescue => e
      log_event('error', "Metadata injection failure: #{e.message}")
    end
    pdf
  end

# --- Template Pre-warming Engine ---
# Executed after all generation methods are defined to ensure scope availability
configure do
  Thread.new do
    sleep 2 # Brief delay to ensure WEBrick is initializing
    log_event('info', "Pre-warming Cosmic Engine...")
    ['invoice', 'report', 'orbital_manifest', 'certificate', 'resume', 'badge', 'cheese_ritual', 'seafood_manifest'].each do |template|
       begin
         # Mock data for pre-warming
         data = { 'title' => 'Warm-up', 'theme' => 'classic' }
         standardized_data = data.reject { |k| ['filename', 'webhook_url'].include?(k) }
         key = Digest::SHA256.hexdigest("#{template}-#{standardized_data.sort.to_h.to_json}")
         
         pdf = case template
               when 'invoice' then generate_invoice_pdf(data)
               when 'report' then generate_report_pdf(data)
               when 'orbital_manifest' then generate_orbital_manifest(data)
               when 'certificate' then generate_certificate_pdf(data)
               when 'resume' then generate_resume_pdf(data)
               when 'badge' then generate_badge_pdf(data)
               when 'cheese_ritual' then generate_cheese_ritual_pdf(data)
               when 'seafood_manifest' then generate_seafood_manifest_pdf(data)
               end
         
         if pdf
           CACHE[key] = {
             success: true,
             pdf_base64: Base64.strict_encode64(pdf.render),
             filename: "#{template}_warmup.pdf",
             signature: (pdf.state.store.info.data[:Signature] rescue nil),
             file_hash: Digest::SHA256.hexdigest(pdf.render)
           }
           log_event('debug', "Pre-warmed template: #{template}")
         end
       rescue => e
         log_event('error', "Pre-warm failed for #{template}: #{e.message}")
       end
     end
    log_event('info', "Engine pre-warmed. Ready for Zero-G operations.")
  end
end

  def generate_report_pdf(data)
    pdf = Prawn::Document.new(page_size: 'A4', margin: 50)
    apply_cosmic_theme(pdf, data['theme'] || 'classic')

    pdf.text data['title'] || 'ANALYTIC REPORT', size: 28, style: :bold
    pdf.move_down 5
    pdf.stroke_horizontal_rule
    pdf.move_down 20

    pdf.text "Author: #{data['author'] || 'System'}", size: 10
    pdf.text "Date: #{data['date'] || Time.now.strftime('%Y-%m-%d')}", size: 10
    pdf.move_down 30

    (data['sections'] || []).each do |section|
      pdf.text section['title'].upcase, size: 14, style: :bold
      pdf.move_down 10
      pdf.text section['content'], size: 11, leading: 4
      pdf.move_down 20
    end

    pdf.number_pages "Page <page> of <total>", at: [pdf.bounds.right - 150, 0], width: 150, align: :right, size: 8
    
    apply_cosmic_watermark(pdf, data['watermark'])
    apply_universal_qr(pdf, data['qrcode'])
    
    # Apply Signature Protocol
    begin
      signature = apply_cosmic_signature(pdf)
      pdf.state.store.info.data[:Signature] = signature
    rescue => e
      log_event('error', "Metadata injection failure: #{e.message}")
    end
    pdf
  end

  def generate_certificate_pdf(data)
    pdf = Prawn::Document.new(page_size: 'A4', page_layout: :landscape, margin: 50)
    apply_cosmic_theme(pdf, data['theme'] || 'classic')
    
    pdf.stroke_color '3366ff'
    pdf.line_width 5
    pdf.stroke_rectangle [0, pdf.bounds.height], pdf.bounds.width, pdf.bounds.height
    
    pdf.move_down 100
    pdf.text "CERTIFICATE OF ACHIEVEMENT", size: 40, style: :bold, align: :center
    pdf.move_down 50
    pdf.text "This cosmic decree recognizes that", size: 18, align: :center
    pdf.move_down 20
    pdf.text data['recipient'] || 'IDENTITY UNKNOWN', size: 32, style: :bold, align: :center
    pdf.move_down 20
    pdf.text "has successfully mastered the protocol", size: 18, align: :center
    pdf.move_down 10
    pdf.text data['course'] || 'COSMIC SYSTEM DESIGN', size: 24, style: :bold, align: :center
    pdf.move_down 60
    
    pdf.text data['issuer'] || 'RUBY++ ACADEMY', align: :center, size: 12
    pdf.text "AUTHORIZED SIGNATURE", align: :center, size: 8, style: :italic
    
    apply_cosmic_watermark(pdf, data['watermark'])
    apply_universal_qr(pdf, data['qrcode'])
    
    # Apply Signature Protocol
    begin
      signature = apply_cosmic_signature(pdf)
      pdf.state.store.info.data[:Signature] = signature
    rescue => e
      log_event('error', "Metadata injection failure: #{e.message}")
    end
    pdf
  end

  def generate_resume_pdf(data)
    pdf = Prawn::Document.new(page_size: 'A4', margin: 40)
    apply_cosmic_theme(pdf, data['theme'] || 'classic')
    
    pdf.text data['name'] || 'IDENTITY UNKNOWN', size: 32, style: :bold
    pdf.text data['contact_info'] || 'Unknown Sector', size: 10, color: '666666'
    pdf.move_down 20
    
    pdf.text "EXECUTIVE SUMMARY", size: 14, style: :bold
    pdf.stroke_horizontal_rule
    pdf.move_down 10
    pdf.text data['summary'] || 'No summary provided.'
    pdf.move_down 20
    
    pdf.text "CORE COMPETENCIES", size: 14, style: :bold
    pdf.stroke_horizontal_rule
    pdf.move_down 10
    pdf.text data['skills'] || 'No skills listed.'
    pdf.move_down 20
    
    pdf.text "EXPERIENCE", size: 14, style: :bold
    pdf.stroke_horizontal_rule
    pdf.move_down 10
    pdf.text data['experience'] || 'No experience data.'
    
    apply_cosmic_watermark(pdf, data['watermark'])
    apply_universal_qr(pdf, data['qrcode'])
    
    # Apply Signature Protocol
    begin
      signature = apply_cosmic_signature(pdf)
      pdf.state.store.info.data[:Signature] = signature
    rescue => e
      log_event('error', "Metadata injection failure: #{e.message}")
    end
    pdf
  end

  def generate_badge_pdf(data)
    pdf = Prawn::Document.new(page_size: [300, 200], margin: 10)
    
    # Background
    pdf.fill_color '050a1f'
    pdf.fill_rectangle [0, 180], 280, 180
    
    # Header
    pdf.fill_color '3366ff'
    pdf.fill_rectangle [0, 180], 280, 40
    pdf.fill_color 'ffffff'
    pdf.text_box data['organization'] || 'COSMIC NODE', 
      at: [10, 175], size: 14, style: :bold
    
    # Content
    pdf.fill_color 'ffffff'
    pdf.text_box data['name'] || 'IDENTITY UNKNOWN', 
      at: [10, 130], size: 16, style: :bold
    pdf.text_box data['role'] || 'SYSTEM ARCHITECT', 
      at: [10, 110], size: 10, style: :italic
    
    # QR Code (Universal Protocol)
    qr_data = data['qrcode'] || data['verification_url'] || "https://node.cosmic.io/verify/#{data['id_number'] || '0000'}"
    apply_universal_qr(pdf, qr_data)
    
    # Watermark (Transparent Overlay)
    apply_cosmic_watermark(pdf, data['watermark'])
    
    # Footer
    pdf.fill_color '666666'
    pdf.text_box "ID: #{data['id_number'] || 'X-7700'}", at: [10, 20], size: 8
    
    # Apply Signature Protocol
    begin
      signature = apply_cosmic_signature(pdf)
      pdf.state.store.info.data[:Signature] = signature
    rescue => e
      log_event('error', "Metadata injection failure: #{e.message}")
    end
    pdf
  end

  def generate_orbital_manifest(data)
    pdf = Prawn::Document.new(page_size: 'A4', margin: [30, 30, 30, 30])
    apply_cosmic_theme(pdf, data['theme'] || 'classic')

    # Header
    pdf.font_size 24
    pdf.text "ORBITAL LOGISTICS MANIFEST", style: :bold, align: :center
    pdf.stroke_horizontal_rule
    pdf.move_down 20

    # Metadata Table
    meta = [
      ["Manifest ID", "OM-#{SecureRandom.hex(4).upcase}"],
      ["Destination", data['destination'] || "Low Earth Orbit (LEO)"],
      ["Launch Window", data['launch_window'] || "2026-02-14 09:00 UTC"],
      ["Carrier", "Cosmic Express Heavy"]
    ]
    pdf.table(meta, width: 535) do
      cells.padding = 8
      cells.border_width = 0.5
    end

    pdf.move_down 30
    pdf.text "CARGO INVENTORY", size: 16, style: :bold
    pdf.move_down 10

    # Inventory Table
    items = [["Item ID", "Description", "Mass (kg)", "Priority"]]
    cargo = data['cargo'] || [
      ["#C-001", "Cryogenic Oxygen Cells", "450", "CRITICAL"],
      ["#C-002", "Navigation Calibration Units", "12", "HIGH"],
      ["#C-003", "Standard Nutrient Packs", "1200", "MEDIUM"]
    ]
    items += cargo

    pdf.table(items, header: true, width: 535) do
      row(0).font_style = :bold
      row(0).background_color = '222222'
      row(0).text_color = 'FFFFFF'
      cells.padding = 8
    end

    # Applied Protocols
    apply_cosmic_watermark(pdf, data['watermark'])
    
    qr_data = data['qrcode'] || (data['qr_verify'] ? "MANIFEST-VERIFIED-#{SecureRandom.uuid}" : nil)
    apply_universal_qr(pdf, qr_data)
    
    if qr_data && data['qr_verify']
      pdf.text_box "Security Hash: #{Digest::SHA256.hexdigest(qr_data)[0..15]}", at: [300, 20], size: 8
    end

    # Apply Signature Protocol
    begin
      signature = apply_cosmic_signature(pdf)
      pdf.state.store.info.data[:Signature] = signature
    rescue => e
      log_event('error', "Metadata injection failure: #{e.message}")
    end
    pdf
  end
