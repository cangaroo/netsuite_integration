module NetsuiteIntegration
  class TransferOrderReceipt < Base
    attr_reader :config, :payload, :ns_order,:order_payload,:receipt,:fulfillment

    def initialize(config, payload = {})
        super(config, payload)
        @config = config
              
        
        @order_payload=payload[:transfer_order]
        
        if pending_fulfillment? || pending_receipt?
            if pending_fulfillment?
               #check if over shipped or over received & update transfer order
               update_fulfillment(ns_order) 
               create_fulfillment
            end

            if  received?
                create_receipt
            end
        end
    end

    def new_receipt?
        new_receipt ||= !find_receipt_by_external_id(receipt_id) 
    end

    def new_fulfillment?
        new_fulfillment ||= !find_fulfillment_by_external_id(receipt_id) 
    end

    def ns_order
        @ns_order ||= NetSuite::Records::TransferOrder.get(ns_id)
    end

    def pending_receipt?
        ns_order.order_status=="_pendingReceipt"  || ns_order.order_status=="_pendingReceiptPartFulfilled"    
    end

    def received?
        order_payload['status'] == 'RECEIVED'
    end

    def sent?
        order_payload['status'] == 'SENT'
    end

    def pending_fulfillment?
        ns_order.order_status=="_pendingFulfillment"   
    end

    def find_receipt_by_external_id(receipt_id)
        NetSuite::Records::ItemReceipt.get(external_id: receipt_id)
        # Silence the error
        # We don't care that the record was not found
        rescue NetSuite::RecordNotFound
    end

    def find_fulfillment_by_external_id(receipt_id)
        NetSuite::Records::ItemFulfillment.get(external_id: receipt_id)
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

    def fulfillment_date
        @fulfillment_date ||=order_payload['fulfillment_date']
    end     
    
    def receipt_memo
        @receipt_memo ||=order_payload['receipt_memo']
    end

    def find_location_by_internal_id(location_id)
        NetSuite::Records::Location.get(internal_id: location_id)
        # Silence the error
        # We don't care that the record was not found
        rescue NetSuite::RecordNotFound
    end

    
    def build_receipt_item_list   
        # NetSuite will through an error when you dont return all items back
        # in the fulfillment request so we just set the quantity to 0 here
        # for those not present in the shipment payload
        @receipt.item_list.items.each do |receipt_item|
                item = order_payload[:line_items].find do |i|
                    i[:sku] == receipt_item.item.name
            end

            if item
                #issue netsuite does not allow partial receipts on transfers always receives full qty
                ####receipt_item.quantity = item[:received]####
                receipt_item.item_receive = true
                if  receipt_item.location.internal_id.nil?
                    receipt_item.location=find_location_by_internal_id(item[:nslocation_id])
                end                   
            else
                receipt_item.quantity = 0
                receipt_item.item_receive = false           
            end
        end
    end 

    def build_fulfillment_item_list   
        # NetSuite will through an error when you dont return all items back
        # in the fulfillment request so we just set the quantity to 0 here
        # for those not present in the shipment payload
        fulfillment.item_list.items.each do |fulfillment_item|
                item = order_payload[:line_items].find do |i|
                    i[:sku] == fulfillment_item.item.name
            end

            if item
                fulfillment_item.quantity = item[:count]
            else
                fulfillment_item.quantity = 0          
            end
        end
    end 

    def create_receipt
        
        if new_receipt?
            @receipt = NetSuite::Records::ItemReceipt.initialize ns_order 
            receipt.external_id= receipt_id 
            receipt.memo=receipt_memo
            receipt.tran_date=received_date.to_datetime
            build_receipt_item_list 
            receipt.add
            if receipt.errors.any?{|e| "WARN" != e.type}
                raise "Receipt create failed: #{receipt.errors.map(&:message)}"
            end 
                                    
        else 
            #suppress this while testing
            #raise "Warning : Duplicate receipt EXT Id: \"#{receipt_id}\" "        
        end
    end

    def create_fulfillment
        
        if new_fulfillment?
            @fulfillment = NetSuite::Records::ItemFulfillment.initialize ns_order 
            fulfillment.external_id=receipt_id 
            fulfillment.memo=receipt_memo
            fulfillment.tran_date=fulfillment_date.to_datetime
            build_fulfillment_item_list 
            fulfillment.add
            if fulfillment.errors.any?{|e| "WARN" != e.type}
                raise "Fullfilment create failed: #{fulfillment.errors.map(&:message)}"
            end 
                                    
        else 
            #suppress this while testing
            #raise "Warning : Duplicate Fulfillment EXT Id: \"#{receipt_id}\" "        
        end
    end                          
   
  

    def over_receipt(status=false)
        @over_receipt ||= status
    end

   
    def update_fulfillment(ns_order)
       
         ns_order.item_list.items.each do |order_item|
            item = order_payload[:line_items].find do |i|
                    i[:sku] == order_item.item.name
            end 
              if item
                  #use greater of the two quantities (count vs receive)
                  new_order_qty=(item[:count].to_i  > item[:received].to_i  ? item[:count].to_i  : item[:received].to_i)
                  if   order_item.quantity.to_i  < new_order_qty                    
                       over_receipt(true)
                       order_item.quantity=new_order_qty
                  end
                else
                  raise  "Item \"#{item[:sku]}\" not found on transfer order"
              end
           end  

          #Update transferorder
          
          if over_receipt
              po=NetSuite::Records::TransferOrder.new({
              internal_id: ns_order.internal_id,
              external_id: ns_order.external_id  })

              attributes = ns_order.attributes
              attributes[:item_list].items.each do |item|
                item.attributes = item.attributes.slice(:line, :quantity)
              end

              po.update({ item_list: attributes[:item_list] })
              if po.errors.any?{|e| "WARN" != e.type}
                raise  "Transfer over receipt update failed: #{po.errors.map(&:message)}"
              end
          end
      end
               
  end
end