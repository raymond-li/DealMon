# Script for checking prices
# Load rules from configuration file
require 'json'
require 'net/http'
require 'nokogiri'
require 'net/smtp'

class Hash
  def recursive_merge(other)
    self.merge(other) { |key, value1, value2| value1.is_a?(Hash) && value2.is_a?(Hash) ? value1.recursive_merge(value2) : value2}
  end

  def recursive_merge!(other)
    self.merge!(other) { |key, value1, value2| value1.is_a?(Hash) && value2.is_a?(Hash) ? value1.recursive_merge(value2) : value2}
  end
end

class Numeric
    def minutes
        60*self
    end
    alias :minute :minutes
    def hours
        60*minutes
    end
    alias :hour :hours
    def days
        24*hours
    end
    alias :day :days
end

# Deal Monitor
# Manages ItemCheckers
#  - Creates checkers based on configuration file
#  - Periodically calls the checker based on config setting
#  - Handles alerts
class DealMon
    attr_accessor :checkers, :conf, :started
    @checkers
    @conf
    @started
    @pids
    @smtp
    def initialize(cfg_path='config.json')
        @started = false
        @checkers = []
        @pids = []
        load_config(cfg_path)
        config_checkers(@conf)
        config_email(@conf)
    end
    def start
        # Fork and sleep based on product check_interval_m time and check_interval_jitter_m time
        checkers.each_with_index do |c, i|
            @pids << every_nish_seconds(c.conf[:check_interval_m].minutes, c.conf[:check_interval_jitter_m].minutes) do
                puts "Checking product. #{c.conf}"
                res = c.check_product
                puts "Checked. #{res}"
                if(res[:deal])
                    handle_alert(res, c)
                end
            end
            # puts "Added pid #{@pids.last}"
        end
    end
    def every_nish_seconds(base, jitter)
        pid = fork do
            offset = rand(-jitter.to_f..jitter.to_f)
            sleep_time = base+offset
            loop do
                before = Time.now
                yield
                interval = sleep_time-(Time.now-before)
                if interval > 0
                    offset = rand(-jitter.to_f..jitter.to_f)
                    sleep_time = base+offset
                    sleep(sleep_time.abs)
                end
            end
        end
        pid
    end
    def stop
        puts "\nStopping DealMon..."
        @pids.each do |pid|
            # Process.detach(pid)
            # puts "Killing process #{pid}"
            begin Process.kill('KILL',pid) rescue Errno::ESRCH end
        end
        @smtp.finish
        puts "DealMon Stopped"
    end
    def handle_alert(deal, checker)
        if(@conf[:settings][:email][:enabled])
            email_list = @conf[:settings][:email][:alert_list]
            # Send to all in list
            if((Time.now-checker.last_email_alert).to_i < @conf[:settings][:email][:cooldown_m].minutes)
                puts "Cooling down for #{c}"
                return # cooldown on each checker
            end
            puts "Sending emails! deal: #{deal}"
            send_email_alerts(email_list, deal)
            checker.last_email_alert = Time.now
        end
    end
    def send_email_alerts(emails, deal)
        smtp_settings = @conf[:settings][:email][:smtp_mailer]
        # @smtp.start(smtp_settings[:domain], smtp_settings[:login], smtp_settings[:password], :login) if !@smtp.started?
        @smtp.start(smtp_settings[:domain], smtp_settings[:login], smtp_settings[:password], :login) do
            emails.each do |em|
                message = <<-MESSAGE_END
From: #{smtp_settings[:from]} <#{smtp_settings[:login]}>
To: <#{em}>
Subject: #{smtp_settings[:subject_prefix]}#{deal[:name]}

Your deal was found!
Product: #{deal[:name]}
Link: #{deal[:link]}
Price: $#{deal[:price]}
Stores: #{deal[:stores]}

Your deal criteria:
#{deal[:criteria]}
                MESSAGE_END
                @smtp.send_message(message, smtp_settings[:from], em)
                puts "Sent email to #{em} about #{deal[:name]}"
            end
        end
    end
    # Create checkers based on conf_hsh settings
    def config_checkers(conf_hsh)
        # puts "conf_hsh: #{conf_hsh.inspect}"
        global_product_settings = conf_hsh[:settings][:global_product_settings]
        conf_hsh[:products].each do |prod_label, prod_conf|
            merged = global_product_settings.recursive_merge({label: prod_label}).recursive_merge!(prod_conf)
            chkr = newChecker(merged)
            @checkers << chkr
        end
    end
    def config_email(conf_hsh)
        # Gmail limits 99 or 2000 emails per day
        # See https://support.google.com/a/answer/176600?hl=en
        # Gmail might be on port 465 (SSL), or 587 (TLS)
        smtp_settings = conf_hsh[:settings][:email][:smtp_mailer]
        @smtp = Net::SMTP.new(smtp_settings[:server], smtp_settings[:port])
        @smtp.enable_starttls if smtp_settings[:security] == "tls"
        # @smtp.start(smtp_settings[:domain], smtp_settings[:login], smtp_settings[:password], :login)
    end
 # protected
    def load_config(cfg_path)
        begin
            file = File.read(cfg_path)
        rescue Errno::ENOENT
            file = ''
        end
        @conf = JSON.parse(file, symbolize_names: true)
    end
    def newChecker(conf_hsh={})
        case conf_hsh[:link]
        when /frys\.com/
            return FrysChecker.new(conf_hsh)
        else
            STDERR.puts "Unrecognized website: #{url}"
            return nil
        end 
    end
end

# Item Checker Base Class
# One created for each product
class ItemChecker
    attr_accessor :last_checked, :last_email_alert
    attr_accessor :conf, :scraped_site
    @conf
    @last_checked
    @last_email_alert
    @scraped_site
    def initialize(conf_hsh)
        @conf = conf_hsh
        @last_email_alert = 0
    end
    def check_product
        ret = {}
        scrape_site
        price = current_price
        stores = stores_in_stock
        ret[:name] = product_name
        ret[:link] = @conf[:link]
        ret[:deal] = true
        if !(price < @conf[:rules][:price_below_usd])
            ret[:deal] = false
        end
        matching_stores = @conf[:rules][:stores] & stores.map {|s| s[:store]}
        if (@conf[:rules][:stock] == 'available') && stores.none?
            ret[:deal] = false
        elsif matching_stores.none? # Check stores match stores in rules
            ret[:deal] = false
        end
        ret[:stores] = ret[:deal]? matching_stores:[]
        ret[:price] = price
        ret[:criteria] = @conf[:rules]
        # Update stats
        @last_checked = Time.now
        ret
    end
    # Up to children to scrape site/call APIs
    def product_name
        @scraped_site[:name]
    end
    def scrape_site
        @scraped_site = {}
    end
    def current_price
        @scraped_site[:price]
    end
    def stores_in_stock
        @scraped_site[:stores_with_stock]
    end
end

class FrysChecker < ItemChecker
    attr_accessor :cookies
    @cookies
    def scrape_site
        @scraped_site ||= {}
        @cookies ||= {}
        # Check product page for name and price
        @scraped_site[:name], @scraped_site[:price] = get_name_price
        # Check nearby stores for availability
        all_stores = get_stores
        @scraped_site[:stores_with_stock] = all_stores.select do |store|
            store[:status] == "Available"
        end
        @scraped_site
    end
    def product_id(link=nil)
        return @product_id if @product_id
        link ||= @conf[:link]
        # look for /product/(\d+)
        @product_id = link.match(/product\/(\d+)/)[1]
    end
    def zip_code
        return @zip_code if @zip_code
        @zip_code = @conf[:rules][:zip_code]
    end
    def get_name_price(prod_id=nil)
        prod_id ||= product_id
        path = "/product/#{prod_id}"
        resp = get_request(path)
        parsed = parse_page(resp.body)
        begin
            name = parsed.at_xpath("//label[@class='product_title']").xpath(".//b").first.content.strip
        rescue StandardError => e
            puts "ERROR! path: #{path}\n"
            # puts resp.body.inspect
            raise e
        end
        price_s = parsed.at_xpath("//label[contains(@id, 'value_#{prod_id}')]").content
        # <label id="l_price1_value_8911983" class="">$68.99</label>
        price = price_s.gsub('$','').to_f
        [name, price]
    end
    def get_stores(prod_id=nil, zip=nil)
        prod_id ||= product_id
        zip ||= zip_code
        path = "/template/product/product_text_normal/nearby_stores.jsp"
        params = {
            zipcode: zip,
            plu: prod_id
        }
        resp = get_request(path, params)
        parsed = parse_page(resp.body)
        stores = parsed.xpath("//td[@class='storeTD']")
        # statuses = parsed.xpath("//td[@class='sStatusTD']") # Requires session. Look at radio button instead
        radios = parsed.xpath("//input[@type='radio' and @onclick and @id and @name and @value]")

        ret = radios.map do |radio|
            radio_status = (radio.attributes['disabled']==nil)? true:false
            sstatus = (radio.parent.parent.at_xpath(".//td[@class='sStatusTD']").text.strip == 'Available')? true:false
            store = radio.parent.parent.at_xpath(".//td[@class='storeTD']").text.gsub('(map)','').strip
            status = (radio_status && sstatus)? 'Available':'UnAvailable'
            {store: store, status: status}
        end
        # Return array of stores [{store: 'San Jose', status: 'Available'}]
        ret
    end
    def domain
        "frys.com"
    end
    def parse_page(page)
        # Use nokogiri to turn page into structured nodes
        html_doc = Nokogiri::HTML(page) do |config|
            config.noblanks
        end
    end
    def get_request(path, query_params={})
        cookie_str = @cookies.map {|pair| pair.join('=') }.join('; ')
        resp = nil
        port = 80
        Net::HTTP.start(domain, port) do |http|
            uri = URI.parse(path)
            uri.query = URI.encode_www_form(query_params)
            resp = http.get(uri.to_s, {'Cookie' => cookie_str})
        end
        # Save cookies, see http://stackoverflow.com/a/9320190
        all_cookies = resp.get_fields('set-cookie')
        cookies_array = []
        all_cookies.each do | cookie |
            cookies_array.push(cookie.split('; ')[0])
        end
        hsh = Hash[cookies_array.map {|c| c.split('=', 2)}]
        @cookies.merge!(hsh)
        resp
    end
end

got_sigint = false
Kernel.trap('INT') {
  got_sigint = true
}

# Start Application
dm = DealMon.new
dm.start
loop do
    if(got_sigint)
        dm.stop
        exit
    end
    sleep 1
end
