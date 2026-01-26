#!/usr/bin/env ruby

require 'webrick'
require 'json'
require 'base64'

class PDFServer < WEBrick::HTTPServlet::AbstractServlet
  def do_GET(request, response)
    case request.path
    when '/'
      response.status = 200
      response['Content-Type'] = 'application/json'
      response.body = {
        service: 'Ruby++ PDF Server',
        version: '2.0.0',
        status: 'running',
        ruby_version: RUBY_VERSION,
        endpoints: {
          'POST /pdf/generate' => 'Generate PDF from data',
          'GET /health' => 'Health check'
        }
      }.to_json
    when '/health'
      response.status = 200
      response['Content-Type'] = 'application/json'
      response.body = {
        status: 'healthy',
        timestamp: Time.now.iso8601,
        version: '2.0.0',
        ruby_version: RUBY_VERSION
      }.to_json
    else
      response.status = 404
      response.body = 'Not Found'
    end
  end

  def do_POST(request, response)
    case request.path
    when '/pdf/generate'
      begin
        data = JSON.parse(request.body)
        
        # Simple PDF generation (mock for now)
        pdf_content = "PDF Title: #{data['title'] || 'Untitled'}\n"
        pdf_content += "Content: #{data['content'] || 'No content'}\n"
        pdf_content += "Generated at: #{Time.now}\n"
        
        response.status = 200
        response['Content-Type'] = 'application/json'
        response.body = {
          success: true,
          pdf_base64: Base64.encode64(pdf_content),
          filename: data['filename'] || 'document.pdf',
          pages: 1,
          size: pdf_content.bytesize,
          note: 'This is a simplified version. Full PDF generation requires Prawn gem.'
        }.to_json
      rescue => e
        response.status = 500
        response['Content-Type'] = 'application/json'
        response.body = {
          success: false,
          error: e.message
        }.to_json
      end
    else
      response.status = 404
      response.body = 'Not Found'
    end
  end
end

# Start server
server = WEBrick::HTTPServer.new(
  Port: ENV['PORT'] || 4567,
  BindAddress: '0.0.0.0'
)

server.mount '/', PDFServer

puts "🚀 Ruby++ PDF Server starting on port #{server.config[:Port]}"
puts "📊 Health check: http://localhost:#{server.config[:Port]}/health"
puts "🌐 Web interface: http://localhost:#{server.config[:Port]}/"

# Handle shutdown gracefully
trap('INT') { server.shutdown }
trap('TERM') { server.shutdown }

server.start