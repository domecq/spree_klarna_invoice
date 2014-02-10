require 'httparty'

module Klarna; end
class Spree::KlarnaPayment < ActiveRecord::Base
  include HTTParty
  base_uri 'http://payment-beta.klarna.com'
  has_many :payments, :as => :source

  validates :social_security_number, :firstname, :lastname, :presence => true
  # attr_accessible :firstname, :lastname, :social_security_number, :invoice_number, :client_ip

  def actions
    %w{capture}
  end

  # Indicates whether its possible to capture the payment
  def can_capture?(payment)
    ['checkout', 'pending', 'processing'].include?(payment.state) && !payment.order.klarna_invoice_number.blank?
  end

  def process!(*opts)
  #def purchase!(*opts)
    logger.debug "\n----------- KlarnaPayment.process! -----------\n"

    order_number = opts[0]
    payment = opts[1]
    order_details = opts[2]
    payment_method = opts[4]

    if self.invoice_number.blank?
      create_invoice(payment)
    else
      logger.error "\n----------- KlarnaPayment.process! -> Order Exists in Klarna with no: #{self.invoice_number} | Order: #{order_number} (#{payment.order.id}) -----------\n"
    end

    capture(payment) if Spree::Config[:auto_capture] && !self.invoice_number.blank?
  end

  # Activate action
  def capture(payment)
    logger.debug "\n----------- KlarnaPayment.capture -----------\n"
    logger.info "Country Code #{payment_method.preferred(:country_code)}"
    logger.info "Store Id #{payment_method.preferred(:store_id)}"
    logger.info "Store Secret #{payment_method.preferred(:store_secret)}"
    payment.update_attribute(:state, 'pending') if payment.state == 'checkout' || payment.state == 'processing'

    begin
      activate_invoice(payment) if payment_method.preferred(:mode) != "test" && payment_method.preferred(:activate_in_days) <= 0
      payment.complete!
      payment.order.update!
      true
    rescue ::Klarna::API::Errors::KlarnaServiceError => e
      payment.order.set_error e.error_message
      gateway_error("KlarnaPayment.process! >>> #{e.error_message}")
    end
  end

  private

  def payment_method
    @payment_method ||= Spree::PaymentMethod::KlarnaInvoice.new
  end

  # Init Klarna instance
  def init_klarna(payment)
    @@klarna ||= setup_klarna(payment)
    @@klarna.timeout = payment_method.preferred(:timeout) unless payment_method.preferred(:timeout) <= 0
  end

  # Setup Klarna connection
  def setup_klarna(payment)
    logger.debug "\n----------- KlarnaPayment.setup_klarna -----------\n"
    require 'klarna'

    #Klarna::setup do |config|
    Klarna.configure do |config|
      config.mode = payment.payments[0].payment_method.preferred(:mode)
      config.country = payment.payments[0].payment_method.preferred(:country_code) # SE
      config.store_id = payment.payments[0].payment_method.preferred(:store_id) # 2029
      config.store_secret = payment.payments[0].payment_method.preferred(:store_secret) # '3FPNSzybArL6vOg'
      config.logging = payment.payments[0].payment_method.preferred(:logging)
      config.http_logging = payment.payments[0].payment_method.preferred(:http_logging)
    end

    begin
      return ::Klarna::API::Client.new(::Klarna.store_id, ::Klarna.store_secret)
    rescue Klarna::API::Errors::KlarnaCredentialsError => e
      payment.order.set_error e.error_message
      gateway_error(e.error_message)
    rescue ::Klarna::API::Errors::KlarnaServiceError => e
      payment.order.set_error e.error_message
      gateway_error(e.error_message)
    end
  end

  # Create Klarna invoice and send to
  def create_invoice(payment)
    logger.debug "\n----------- KlarnaPayment.create_invoice -----------\n"

    order = payment.payments[0].order
    # Initialize Klarna connection
    init_klarna(payment)

    #ssn = "411028-8083" # Not approved
    #ssn = "410321-9202" # Approved

    ssn =  self.social_security_number

    # Implement verification to Klarna to get secret
    sso_secret = @@klarna.send(:digest, payment_method.preferred(:store_id), ssn, payment_method.preferred(:store_secret))
    logger.debug "\n----------- SSO Secret #{sso_secret} for #{ssn} -----------\n"
    order_items = []

    payment_amount = 0

    default_tax_rate = Spree::TaxRate.find(1)
    # Add products
    order.line_items.each do |item|
      logger.debug "\n----------- Item: #{item.quantity}, #{item.product.sku}, #{item.product.name}, #{item.amount} -----------\n"
      flags = {}
      flags[:INC_VAT] = ::Klarna::API::GOODS[:INC_VAT] if default_tax_rate.included_in_price
      order_items << @@klarna.make_goods(item.quantity, item.product.sku, item.product.name, item.product.price * 100.00, default_tax_rate.amount*100, nil, flags)

      if ! default_tax_rate.included_in_price
        item.product.price = item.product.price * (default_tax_rate.amount + 1)
      end

      payment_amount += item.product.price
    end

    order.adjustments.eligible.each do |adjustment|
      next if (adjustment.originator_type == 'Spree::TaxRate') or (adjustment.amount === 0)

      flags = {}
      flags[:INC_VAT] = ::Klarna::API::GOODS[:INC_VAT] if default_tax_rate.included_in_price
      flags[:IS_HANDLING] = ::Klarna::API::GOODS[:IS_HANDLING] if adjustment.label == I18n.t(:invoice_fee)
      flags[:IS_SHIPMENT] = ::Klarna::API::GOODS[:IS_SHIPMENT] if adjustment.originator_type == 'Spree::ShippingMethod'
      amount = 100 * adjustment.amount
      order_items << @@klarna.make_goods(1, '', adjustment.label, amount, default_tax_rate.amount * 100, nil, flags)

      if ! default_tax_rate.included_in_price
        adjustment.amount = adjustment.amount * (default_tax_rate.amount + 1)
      end

      payment_amount += adjustment.amount
      logger.info "\n----------- Order: #{order.number} (#{order.id}) | payment_amount: #{payment_amount} -----------\n"
    end

    # Create address
    address = @@klarna.make_address("", order.bill_address.address1, order.bill_address.zipcode.delete(' ').to_i, order.bill_address.city, order.bill_address.country.iso, order.bill_address.phone, nil, order.email)

    # Do transaction and create invoice in Klarna
    begin
      logger.debug "\n----------- add_transaction -----------\n"

      #shipping_cost = payment.order.ship_total * 100
      #shipping_cost = shipping_cost * (1 + Spree::TaxRate.default) if Spree::Config[:shipment_inc_vat]

      # Client IP
      #client_ip = payment_method.preferred(:mode) == "test" ? "85.230.98.196" : self.client_ip
      client_ip = "85.230.98.196"

      # Set ready date
      ready_date = payment_method.preferred(:activate_in_days) > 0 ? (DateTime.now.to_date + payment_method.preferred(:activate_in_days)).to_s : nil

      # Set flags
      flags = {}
      flags[:TEST_MODE] = TRUE unless payment_method.preferred(:mode) == "production"
      flags[:AUTO_ACTIVATE] = TRUE if payment_method.preferred(:auto_activate)

      # Debug output
      # logger.debug "\n----------- add_transaction - Shipping: #{shipping_cost.to_i} -----------\n"
      logger.debug "\n----------- add_transaction - Ready date: #{ready_date} -----------\n"
      logger.debug "\n----------- add_transaction - Flags: #{flags} -----------\n"
      logger.debug "\n----------- add_transaction - Client IP: #{self.client_ip} -----------\n"

      invoice_no = @@klarna.add_transaction(
          "USER-#{order.user_id}",                  # store_user_id,
          order.number,                             # order_id,
          order_items,                                      # articles,
          0,                                                # shipping_fee,
          0,                                                # handling_fee,
          :NORMAL,                                          # shipment_type,
          ssn,                                              # pno,
          (order.bill_address.company.blank? ? order.bill_address.firstname.encode("iso-8859-1") : order.bill_address.company.encode("iso-8859-1")), # first_name,
          order.bill_address.lastname.encode("iso-8859-1"), # last_name,
          address,                                          # address,
          client_ip,                                        # client_ip,
          payment_method.preferred(:currency_code), # currency,
          payment_method.preferred(:country_code),  # country,
          payment_method.preferred(:language_code), # language,
          payment_method.preferred(:country_code),  # pno_encoding,
          nil,                                              # pclass = nil,
          nil,                                              # annual_salary = nil,
          nil,                                              # password = nil,
          ready_date,                                       # ready_date = nil,
          nil,                                              # comment = nil,
          nil,                                              # rand_string = nil,
          flags)                                            # flags = nil

      logger.info "\n----------- Order: #{order.number} (#{order.id}) | Invoice: #{invoice_no} -----------\n"
      logger.info "\n----------- Order: #{order.number} (#{order.id}) | payment_amount: #{payment_amount} -----------\n"

      payment.payments[0].update_attribute(:amount, payment_amount)

    rescue ::Klarna::API::Errors::KlarnaServiceError => e
      order.set_error e.error_message
      gateway_error(e.error_message)
    end
  end

  # Active Klarna Invoice
  def activate_invoice(payment)
    logger.debug "\n----------- KlarnaPayment.activate_invoice -----------\n"
    init_klarna(payment)

    raise Spree::Core::GatewayError.new(t(:missing_invoice_number)) if self.invoice_number.blank?

    @@klarna.activate_invoice(self.invoice_number)
    send_invoice(payment)
  end

  def send_invoice(payment)
    logger.debug "\n----------- KlarnaPayment.send_invoice -----------\n"
    init_klarna(payment)

    raise Spree::Core::GatewayError.new(t(:missing_invoice_number)) if self.invoice_number.blank?

    if payment_method.preferred(:email_invoice)
      logger.info "\n----------- KlarnaPayment.send_invoice : Email -----------\n"
      @@klarna.email_invoice(self.invoice_number)
    end

    if payment_method.preferred(:send_invoice)
      logger.info "\n----------- KlarnaPayment.send_invoice : Post -----------\n"
      @@klarna.send_invoice(self.invoice_number)
    end
  end

  def gateway_error(text)
    msg = "#{text}"
    logger.error("KlarnaInvoice >>> #{msg}")
    raise Spree::Core::GatewayError.new(msg)
  end
end
