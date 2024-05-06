# frozen_string_literal: true

module Engine
  module Game
    module G1849
      class Corporation < Engine::Corporation
        attr_reader :token_fee
        attr_accessor :next_to_par, :closed_recently, :slot_open, :reached_max_value, :sms_hexes, :e_token

        def initialize(sym:, name:, **opts)
          super
          @token_fee = opts[:token_fee]
          @slot_open = true
          @next_to_par = false
          shares.last.last_cert = true
          shares.last.double_cert = true
        end

        def corp_loans_text
          'Bonds Issued'
        end
      end
    end
  end
end
