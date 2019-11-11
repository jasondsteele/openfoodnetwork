require 'open_food_network/spree_api_key_loader'

module Spree
  module Admin
    class OrdersController < Spree::Admin::BaseController
      require 'spree/core/gateway_error'
      include OpenFoodNetwork::SpreeApiKeyLoader
      helper CheckoutHelper

      before_filter :initialize_order_events
      before_filter :load_order, only: [:edit, :update, :fire, :resend,
                                        :open_adjustments, :close_adjustments]

      before_filter :load_order, only: %i[show edit update fire resend invoice print print_ticket]

      before_filter :load_distribution_choices, only: [:new, :edit, :update]

      # Ensure that the distributor is set for an order when
      before_filter :ensure_distribution, only: :new

      # After updating an order, the fees should be updated as well
      # Currently, adding or deleting line items does not trigger updating the
      # fees! This is a quick fix for that.
      # TODO: update fees when adding/removing line items
      # instead of the update_distribution_charge method.
      after_filter :update_distribution_charge, only: :update

      before_filter :require_distributor_abn, only: :invoice

      respond_to :html, :json

      def index
        # Overriding the action so we only render the page template. An angular request
        # within the page then fetches the data it needs from Api::OrdersController
      end

      def new
        @order = Order.create
        @order.created_by = try_spree_current_user
        @order.save
        redirect_to edit_admin_order_url(@order)
      end

      def edit
        @order.shipments.map(&:refresh_rates)

        AdvanceOrderService.new(@order).call

        # The payment step shows an error of 'No pending payments'
        # Clearing the errors from the order object will stop this error
        # appearing on the edit page where we don't want it to.
        @order.errors.clear
      end

      def update
        unless @order.update_attributes(params[:order]) && @order.line_items.present?
          if @order.line_items.empty?
            @order.errors.add(:line_items, Spree.t('errors.messages.blank'))
          end
          return redirect_to(edit_admin_order_path(@order),
                             flash: { error: @order.errors.full_messages.join(', ') })
        end

        @order.update!
        if @order.complete?
          redirect_to edit_admin_order_path(@order)
        else
          # Jump to next step if order is not complete
          redirect_to admin_order_customer_path(@order)
        end
      end

      def bulk_management
        load_spree_api_key
      end

      def fire
        # TODO - Possible security check here
        #   Right now any admin can before any transition (and the state machine
        #   itself will make sure transitions are not applied in the wrong state)
        event = params[:e]
        if @order.public_send(event.to_s)
          flash[:success] = Spree.t(:order_updated)
        else
          flash[:error] = Spree.t(:cannot_perform_operation)
        end
      rescue Spree::Core::GatewayError => e
        flash[:error] = e.message.to_s
      ensure
        redirect_to :back
      end

      def resend
        Spree::OrderMailer.confirm_email_for_customer(@order.id, true).deliver
        flash[:success] = t(:order_email_resent)

        respond_with(@order) { |format| format.html { redirect_to :back } }
      end

      def invoice
        pdf = InvoiceRenderer.new.render_to_string(@order)

        Spree::OrderMailer.invoice_email(@order.id, pdf).deliver
        flash[:success] = t('admin.orders.invoice_email_sent')

        respond_with(@order) { |format| format.html { redirect_to edit_admin_order_path(@order) } }
      end

      def print
        render InvoiceRenderer.new.args(@order)
      end

      def print_ticket
        render template: "spree/admin/orders/ticket", layout: false
      end

      def update_distribution_charge
        @order.update_distribution_charge!
      end

      def open_adjustments
        adjustments = @order.adjustments.where(state: 'closed')
        adjustments.update_all(state: 'open')
        flash[:success] = Spree.t(:all_adjustments_opened)

        respond_with(@order) { |format| format.html { redirect_to :back } }
      end

      def close_adjustments
        adjustments = @order.adjustments.where(state: 'open')
        adjustments.update_all(state: 'closed')
        flash[:success] = Spree.t(:all_adjustments_closed)

        respond_with(@order) { |format| format.html { redirect_to :back } }
      end

      private

      def load_order
        @order = Order.find_by_number!(params[:id], include: :adjustments) if params[:id]
        authorize! action, @order
      end

      def initialize_order_events
        @order_events = %w{cancel resume}
      end

      def model_class
        Spree::Order
      end

      def require_distributor_abn
        return if @order.distributor.abn.present?

        flash[:error] = t(:must_have_valid_business_number,
                          enterprise_name: @order.distributor.name)
        respond_with(@order) { |format| format.html { redirect_to edit_admin_order_path(@order) } }
      end

      def load_distribution_choices
        @shops = Enterprise.is_distributor.managed_by(spree_current_user).by_name

        ocs = OrderCycle.managed_by(spree_current_user)
        @order_cycles = ocs.soonest_closing +
                        ocs.soonest_opening +
                        ocs.closed +
                        ocs.undated
      end

      def ensure_distribution
        unless @order
          @order = Spree::Order.new
          @order.generate_order_number
          @order.save!
        end
        return if @order.distribution_set?

        render 'set_distribution', locals: { order: @order }
      end
    end
  end
end
