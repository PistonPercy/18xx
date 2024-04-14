# frozen_string_literal: true

module Engine
  module Game
    module G18Norway
      module Corporations
        CORPORATIONS = [
          {
            float_percent: 60,
            sym: 'HB',
            name: 'Hovedbanen',
            logo: '18_norway/HB',
            simple_logo: '18_norway/HB.alt',
            tokens: [0, 40, 100, 100, 100],
            shares: [40, 20, 20, 20],
            coordinates: 'G29',
            city: 2,
            color: '#32763f',
          },
          {
            float_percent: 60,
            sym: 'DB',
            name: 'Dovrebanen',
            logo: '18_norway/DB',
            simple_logo: '18_norway/DB.alt',
            tokens: [0, 40, 100, 100],
            shares: [40, 20, 20, 20],
            color: '#025aaa',
            coordinates: 'G17',
          },
          {
            float_percent: 60,
            sym: 'BB',
            name: 'Bergensbanen',
            logo: '18_norway/BB',
            simple_logo: '18_norway/BB.alt',
            tokens: [0, 40, 100, 100],
            shares: [40, 20, 20, 20],
            coordinates: 'B26',
            color: '#d1232a',
          },
          {
            float_percent: 60,
            sym: 'RB',
            name: 'Raumabanen ',
            logo: '18_norway/RB',
            simple_logo: '18_norway/RB.alt',
            tokens: [0, 40, 100, 100],
            shares: [40, 20, 20, 20],
            color: :'#474548',
            coordinates: 'E19',
          },
          {
            float_percent: 60,
            sym: 'SB',
            name: 'Sørlandsbanen',
            logo: '18_norway/SB',
            simple_logo: '18_norway/SB.alt',
            tokens: [0, 40, 100, 100],
            shares: [40, 20, 20, 20],
            color: :'#FFF500',
            text_color: 'black',
            coordinates: 'C35',
          },
          {
            float_percent: 60,
            sym: 'JB',
            name: 'Jærbanen',
            logo: '18_norway/JB',
            simple_logo: '18_norway/JB.alt',
            tokens: [0, 40, 100, 100],
            shares: [40, 20, 20, 20],
            color: :'#d88e39',
            coordinates: 'B32',
          },
          {
            float_percent: 60,
            sym: 'VB',
            name: 'Vestfoldsbanen',
            logo: '18_norway/VB',
            simple_logo: '18_norway/VB.alt',
            tokens: [0, 40, 100, 100],
            shares: [40, 20, 20, 20],
            color: :'#ADD8E6',
            text_color: 'black',
            coordinates: 'F30',
          },
          {
            float_percent: 60,
            sym: 'ØB',
            name: 'Østfoldbanen',
            logo: '18_norway/OB',
            simple_logo: '18_norway/OB.alt',
            tokens: [0, 40, 100, 100],
            shares: [40, 20, 20, 20],
            coordinates: 'G31',
            color: :'#95c054',
          },
        ].freeze
      end
    end
  end
end
