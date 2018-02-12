require "sinatra"
require "endpoint_base"

require File.expand_path(File.dirname(__FILE__) + '/netsuite_integration')

class NetsuiteEndpoint < EndpointBase::Sinatra::Base
  set :logging, true
  # suppress netsuite warnings
  set :show_exceptions, false

  error Errno::ENOENT, NetSuite::RecordNotFound, NetsuiteIntegration::NonInventoryItemException do
    result 500, env['sinatra.error'].message
  end

  error Savon::SOAPFault do
    result 500, env['sinatra.error'].to_s
  end

  before do
    @config['netsuite_last_updated_after'] ||= Time.at(@payload["last_poll"].to_i).to_s if @payload.present?

    if config = @config
      # https://github.com/wombat/netsuite_integration/pull/27
      # Set connection/flow parameters with environment variables if they aren't already set from the request
      %w(email password account role sandbox api_version wsdl_url silent).each do |env_suffix|
        if ENV["NETSUITE_#{env_suffix.upcase}"].present? && config["netsuite_#{env_suffix}"].nil?
          config["netsuite_#{env_suffix}"] = ENV["NETSUITE_#{env_suffix.upcase}"]
        end
      end

      @netsuite_client ||= NetSuite.configure do
        reset!

        if config['netsuite_wsdl_url'].present?
          wsdl config['netsuite_wsdl_url']
        end

        if config['netsuite_api_version'].present?
          api_version config['netsuite_api_version']
        else
          api_version "2013_2"
        end

        if config['netsuite_role'].present?
          role config['netsuite_role']
        else
          role 3
        end

        sandbox config['netsuite_sandbox'].to_s == "true" || config['netsuite_sandbox'].to_s == "1"

        account      config.fetch('netsuite_account')
        consumer_key config.fetch('netsuite_consumer_key')
        consumer_secret config.fetch('netsuite_consumer_secret')
        token_id config.fetch('netsuite_token_id')
        token_secret config.fetch('netsuite_token_secret')
        wsdl_domain  ENV['NETSUITE_WSDL_DOMAIN'] || 'webservices.na1.netsuite.com'

        read_timeout 240
        log_level    :info
      end
    end
  end

  def self.fetch_endpoint(path, service_class, key)
    post path do
      service = service_class.new(@config)

      service.messages.each do |message|
        add_object key, message
      end

      if service.collection.any?
        add_parameter 'netsuite_last_updated_after', service.last_modified_date
      else
        add_parameter 'netsuite_last_updated_after', @config['netsuite_last_updated_after']
        add_value key.pluralize, []
      end

      count = service.messages.count
      @summary = "#{count} #{key.pluralize count} found in NetSuite"

      result 200, @summary
    end
  end

  fetch_endpoint '/get_products', NetsuiteIntegration::Product, "product"
  fetch_endpoint '/get_purchase_orders', NetsuiteIntegration::PurchaseOrder, "purchase_order"
  fetch_endpoint '/get_transfer_orders', NetsuiteIntegration::TransferOrder, "transfer_order"
  fetch_endpoint '/get_vendors', NetsuiteIntegration::Vendor, "vendor"

  ['/add_order', '/update_order'].each do |path|
    post path do
      begin
        create_or_update_order
      rescue NetsuiteIntegration::CreationFailCustomerException => e
        result 500, "Could not save customer #{@payload[:order][:email]}: #{e.message}"
      end
    end
  end

  post '/cancel_order' do
    if order = sales_order_service.find_by_external_id(@payload[:order][:number] || @payload[:order][:id])
      if customer_record_exists?
        refund = NetsuiteIntegration::Refund.new(@config, @payload, order)
        if refund.process!
          summary = "Customer Refund created and NetSuite Sales Order #{@payload[:order][:number]} was closed"
          result 200, summary
        else
          summary = "Failed to create a Customer Refund and close the NetSuite Sales Order #{@payload[:order][:number]}"
          result 500, summary
        end
      else
        sales_order_service.close!(order)
        result 200, "NetSuite Sales Order #{@payload[:order][:number]} was closed"
      end
    else
      result 500, "NetSuite Sales Order not found for order #{@payload[:order][:number] || @payload[:order][:id]}"
    end
  end

  post '/add_inventory_adjustment' do

    receipt = NetsuiteIntegration::InventoryAdjustment.new(@config, @payload)
    summary = "Netsuite Inventory Adjustment Created "
    result 200, summary
  end

  post '/add_purchase_order_receipt' do

    receipt = NetsuiteIntegration::PurchaseOrderReceipt.new(@config, @payload)
    summary = "Netsuite Receipt Created "
    result 200, summary
  end

  post '/add_transfer_order_receipt' do

    receipt = NetsuiteIntegration::TransferOrderReceipt.new(@config, @payload)
    summary = "Netsuite Receipt Created "
    result 200, summary
  end

  post '/maintain_inventory_item' do

    receipt = NetsuiteIntegration::MaintainInventoryItem.new(@config, @payload)
    summary = "Netsuite Item Created/Updated "
    result 200, summary
  end

  post '/add_gl_journal' do

    receipt = NetsuiteIntegration::GlJournal.new(@config, @payload)
    summary = "Netsuite GL Journal Created "
    result 200, summary
  end


  post '/get_inventory' do
    begin
      stock = NetsuiteIntegration::InventoryStock.new(@config, @payload)

      if stock.collection? && stock.inventory_units.present?
        stock.inventory_units.each { |unit| add_object :inventory, unit }
        count = stock.inventory_units.count
        summary = "#{count} #{"inventory units".pluralize count} fetched from NetSuite"

        add_parameter 'netsuite_poll_stock_timestamp', stock.last_modified_date

      elsif stock.sku.present?

        add_object :inventory, { id: stock.sku, sku: stock.sku, quantity: stock.quantity_available }
        count = stock.quantity_available
        summary = "#{count} #{"unit".pluralize count} available of #{stock.sku} according to NetSuite"
      end

      result 200, summary
    rescue NetSuite::RecordNotFound
      result 200
    end
  end

  post '/get_shipments' do
    shipment = NetsuiteIntegration::Shipment.new(@config, @payload)

    if !shipment.latest_fulfillments.empty?

      count = shipment.latest_fulfillments.count
      summary = "#{count} #{"shipment".pluralize count} found in NetSuite"

      add_parameter 'netsuite_poll_fulfillment_timestamp', shipment.last_modified_date
      shipment.messages.each { |s| add_object :shipment, s }

      result 200, summary
    else
      result 200
    end
  end

  post '/add_shipment' do
    order = NetsuiteIntegration::Shipment.new(@config, @payload).import
    result 200, "Order #{order.external_id} fulfilled in NetSuite # #{order.tran_id}"
  end

  private
  # NOTE move this somewhere else ..
  def create_or_update_order
    order = NetsuiteIntegration::Order.new(@config, @payload)

    error_notification = ""
    summary = ""

    if order.imported?
      if order.update
        summary << "Order #{order.existing_sales_order.external_id} updated on NetSuite # #{order.existing_sales_order.tran_id}"
      else
        error_notification << "Failed to update order #{order.sales_order.external_id} into Netsuite: #{order.errors}"
      end
    else
      if order.create
        summary << "Order #{order.sales_order.external_id} sent to NetSuite # #{order.sales_order.tran_id}"
      else
        error_notification << "Failed to import order #{order.sales_order.external_id} into Netsuite: #{order.errors}"
      end
    end

    if order.paid? && !error_notification.present?
      customer_deposit = NetsuiteIntegration::Services::CustomerDeposit.new(@config, @payload)
      records = customer_deposit.create_records order.sales_order

      errors = records.map(&:errors).compact.flatten
      errors = errors.map(&:message).flatten

      if errors.any?
        error_notification << " Failed to set up Customer Deposit for #{(order.existing_sales_order || order.sales_order).external_id}: #{errors.join(", ")}"
      end

      if customer_deposit.persisted
        summary << ". Customer Deposit set up for Sales Order #{(order.existing_sales_order || order.sales_order).tran_id}"
      end
    end

    if any_payments_void? && !error_notification.present?
      refund = NetsuiteIntegration::Refund.new(@config, @payload, order.existing_sales_order, "void")

      unless refund.service.find_by_external_id(refund.deposits)
        if refund.create
          summary << ". Customer Refund created for #{@payload[:order][:number]}"
        else
          error_notification << "Failed to create a Customer Refund for order #{@payload[:order][:number]}"
        end
      end
    end

    if error_notification.present?
      result 500, error_notification
    else
      result 200, summary
    end
  end

  def customer_record_exists?
    @payload[:order][:payments] && @payload[:order][:payments].any?
  end

  def sales_order_service
    @sales_order_service ||= NetsuiteIntegration::Services::SalesOrder.new(@config)
  end

  def any_payments_void?
    @payload[:order][:payments].any? do |p|
      p[:status] == "void"
    end
  end
end
