module NetsuiteIntegration
  class Vendor
    attr_reader :config, :collection

    def initialize(config)
      @config = config
      @collection = Services::Vendor.new(@config).latest
    end

    def messages
      @messages ||= vendors
    end

    def last_modified_date
      collection.last.last_modified_date.utc + 1.second
    end

    def vendors
      collection.map do |vendor|       
        {
          id: vendor.entity_id,
          internal_id: vendor.internal_id,
          name: vendor.company_name,
          category: vendor.category.name,
          subsidiary: vendor.subsidiary.name,
          payables_account: vendor.payables_account.attributes[:name],
          channel: 'NetSuite'
        }
      end
    end
  end
end
