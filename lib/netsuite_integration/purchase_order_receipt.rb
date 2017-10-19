module NetsuiteIntegration
  class PurchaseOrderReceipt < Base
    attr_reader :config, :payload, :ns_order,:order_payload,:receipt

    def initialize(config, payload = {})
      super(config, payload)
      @config = config
      @over_receipt=false
      @order_payload = payload[:purchase_order]
      if new_receipt?

            update_po_overreceipt(ns_order)

            @receipt = NetSuite::Records::ItemReceipt.initialize ns_order
            receipt.external_id=receipt_id
            receipt.memo=receipt_memo
            receipt.tran_date=NetSuite::Utilities.normalize_datetime_to_netsuite(received_date.to_datetime)
            build_item_list

            # add new receipt after updating the po
            receipt.add
            if receipt.errors.any?{|e| "WARN" != e.type}
                raise "Receipt create failed: #{receipt.errors.map(&:message)}"
            end
        end
    end

    def new_receipt?
        @new_receipt ||= !find_rec_by_external_id(receipt_id)
    end

    def ns_order
        @ns_order ||= NetSuite::Records::PurchaseOrder.get(ns_id)
    end

    def find_rec_by_external_id(receipt_id)
        NetSuite::Records::ItemReceipt.get(external_id: receipt_id)
        # Silence the error
        # We don't care that the record was not found
        rescue NetSuite::RecordNotFound
    end

    def find_location_by_internal_id(location_id)
        NetSuite::Records::Location.get(internal_id: location_id)
        # Silence the error
        # We don't care that the record was not found
        rescue NetSuite::RecordNotFound
    end

    def receipt_id
        @receipt_id  ||=order_payload['receipt_id']
    end

    def ns_id
        @ns_id ||=order_payload['id']
    end

    def received_date
        @received_date ||=order_payload['received_date']
    end

    def receipt_memo
        @receipt_memo ||=order_payload['receipt_memo']
    end



    def build_item_list
        # NetSuite will through an error when you dont return all items back
        # in the fulfillment request so we just set the quantity to 0 here
        # for those not present in the shipment payload
        @receipt.item_list.items.each do |receipt_item|
                item = order_payload[:line_items].find do |i|
                i[:sku] == receipt_item.item.name
            end

            if  item && item[:received].to_i > 0
                  receipt_item.quantity = item[:received].to_i
                  receipt_item.item_receive = true

                if receipt_item.location.internal_id.nil?
                   receipt_item.location=find_location_by_internal_id(item[:location])
                end

            else
                  receipt_item.quantity = 0
                  receipt_item.item_receive = false
            end
        end
    end

     def update_po_overreceipt(ns_order)
            ns_order.item_list.items.each do |order_item|
            item = order_payload[:line_items].find do |i|  i[:sku] == order_item.item.name end
              if item
                #reopen po if it has been closed by mistake!
                if order_item.is_closed
                   order_item.is_closed=false
                   @over_receipt=true
                end
                  #check for over receipts!
                  if   (order_item.quantity.to_i - order_item.quantity_received.to_i)  < item[:received].to_i
                      #first overreceipt works free of charge no update required!
                    if order_item.quantity_received.to_i !=0
                        @over_receipt=true
                        order_item.quantity=
                        (order_item.quantity_received.to_i + item[:received].to_i)
                    end
                  end
               end
           end

          #Update po

          if @over_receipt
              po=NetSuite::Records::PurchaseOrder.new({
              internal_id: ns_order.internal_id,
              external_id: ns_order.external_id  })

              attributes = ns_order.attributes
              attributes[:item_list].items.each do |item|
                item.attributes = item.attributes.slice(:line, :quantity, :is_closed)
              end

              po.update({ item_list: attributes[:item_list] })
              if po.errors.any?{|e| "WARN" != e.type}
                raise  "PO over receipt update failed: #{po.errors.map(&:message)}"
              end
          end
      end

  end
end