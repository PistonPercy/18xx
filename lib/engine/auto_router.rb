# frozen_string_literal: true

# backtick_javascript: true

require_relative 'game_error'
require_relative 'route'

module Engine
  class AutoRouter
    attr_accessor :running

    def initialize(game, flash = nil)
      @game = game
      @next_hexside_bit = 0
      @flash = flash
    end

    def compute_new(corporation, **opts)
      # we don't reverse in the new one since we select trains in reverse order
      trains = @game.route_trains(corporation).sort_by(&:price)
      train_routes, path_walk_timed_out = path(trains, corporation, **opts)
      if path_walk_timed_out
        @flash&.call('Auto route path walk failed to complete (PATH TIMEOUT)')
      end
      new_route(train_routes, **opts)
    end

    def new_route(trains_to_routes, **opts)
      callback = opts[:callback]
      @running = true
      %x{
          let start = performance.now()
          g_update = callback
          new_autoroute(self, trains_to_routes).then((routes) => {
            // Fix up the revenue calculations since routes revenue can be
            // impacted by each other
            self.$real_revenue(routes)
            self.running = false
            console.log("AutoRouter took " + (performance.now() - start) + "ms")
            callback(routes);
          }).catch((e) => {
            self.flash("Auto route selection failed to complete (" + e + ")");
            console.log(e);
            self.running = false;
            callback([]);
          });
        }
    end

    def real_revenue(routes)
      routes.each do |route|
        route.clear_cache!(only_revenue: true)
        route.routes = routes
        route.revenue
      end
      @game.routes_revenue(routes)
    rescue Exception
      -1
    end

    def compute(corporation, **opts)
      trains = @game.route_trains(corporation).sort_by(&:price).reverse

      train_groups =
        if (groups = @game.class::TRAIN_AUTOROUTE_GROUPS)
          trains.group_by { |t| groups.index { |g| g.include?(t.name) } }.values
        else
          [trains]
        end

      routes = opts.delete(:routes)

      final_routes = train_groups.flat_map do |train_group|
        opts[:routes] = routes.select { |r| train_group.include?(r.train) }
        compute_for_train_group(train_group, corporation, **opts)
      end

      # a route's revenue calculation can depend on other routes, so we need to
      # recalculate revenue for the final set of routes.
      # This fixes https://github.com/tobymao/18xx/issues/11078 / https://github.com/tobymao/18xx/issues/11036
      real_revenue final_routes
      final_routes
    end

    def path(trains, corporation, **opts)
      static = opts[:routes] || []
      path_timeout = opts[:path_timeout] || 30
      route_limit = opts[:route_limit] || 10_000

      connections = {}

      graph = @game.graph_for_entity(corporation)
      nodes = graph.connected_nodes(corporation).keys.sort_by do |node|
        revenue = trains
          .map { |train| node.route_revenue(@game.phase, train) }
          .max
        [
          node.tokened_by?(corporation) ? 0 : 1,
          node.offboard? ? 0 : 1,
          -revenue,
        ]
      end

      path_walk_timed_out = false
      now = Time.now

      skip_paths = static.flat_map(&:paths).to_h { |path| [path, true] }
      # if only routing for subset of trains, omit the trains we won't assemble routes for
      skip_trains = static.flat_map(:train).to_a
      trains -= skip_trains

      train_routes = Hash.new { |h, k| h[k] = [] }    # map of train to route list
      hexside_bits = Hash.new { |h, k| h[k] = 0 }     # map of hexside_id to bit number
      @next_hexside_bit = 0

      nodes.each do |node|
        if Time.now - now > path_timeout
          LOGGER.debug('Path timeout reached')
          path_walk_timed_out = true
          break
        else
          LOGGER.debug { "Path search: #{nodes.index(node)} / #{nodes.size} - paths starting from #{node.hex.name}" }
        end

        walk_corporation = graph.no_blocking? ? nil : corporation
        node.walk(corporation: walk_corporation, skip_paths: skip_paths) do |_, vp|
          paths = vp.keys
          chains = []
          chain = []
          left = nil
          right = nil
          last_left = nil
          last_right = nil

          complete = lambda do
            chains << { nodes: [left, right], paths: chain, hexes: chain.map(&:hex) }
            last_left = left
            last_right = right
            left, right = nil
            chain = []
          end

          assign = lambda do |a, b|
            if a && b
              if a == last_left || b == last_right
                left = b
                right = a
              else
                left = a
                right = b
              end
              complete.call
            elsif !left
              left = a || b
            elsif !right
              right = a || b
              complete.call
            end
          end

          paths.each do |path|
            chain << path
            a, b = path.nodes

            assign.call(a, b) if a || b
          end

          # a 1-city Local train will have no chains but will have a left; route.revenue will reject if not valid for game
          if chains.empty?
            next unless left

            chains << { nodes: [left, nil], paths: [] }

            # use the Local train's 1 city instead of any paths as their key;
            # only 1 train can visit each city, but we want Locals to be able to
            # visit multiple different cities if a corporation has more than one
            # of them
            id = [left]
          else
            id = chains.flat_map { |c| c[:paths] }.sort!
          end

          next if connections[id]

          connections[id] = chains.map do |c|
            { left: c[:nodes][0], right: c[:nodes][1], chain: c }
          end

          connection = connections[id]

          # each train has opportunity to vote to abort a branch of this node's path-walk tree
          path_abort = trains.to_h { |train| [train, true] }

          # build a test route for each train, use route.revenue to check for errors, keep the good ones
          trains.each  do |train|
            route = Engine::Route.new(
              @game,
              @game.phase,
              train,
              # we have to clone to prevent multiple routes having the same connection array.
              # If we don't clone, then later route.touch_node calls will affect all routes with
              # the same connection array
              connection_data: connection.clone,
              bitfield: bitfield_from_connection(connection, hexside_bits),
            )
            route.routes = [route]
            route.revenue(suppress_check_other: true) # defer route-collection checks til later
            train_routes[train] << route
          rescue RouteTooLong
            # ignore for this train, and abort walking this path if ignored for all trains
            path_abort.delete(train)
          rescue ReusesCity
            path_abort.clear
          rescue NoToken, RouteTooShort, GameError # rubocop:disable Lint/SuppressedException
          end

          next :abort if path_abort.empty?
        end
      end

      # Check that there are no duplicate hexside bits (algorithm error)
      LOGGER.debug do
        "Evaluated #{connections.size} paths, found #{@next_hexside_bit} unique hexsides, and found valid routes "\
          "#{train_routes.map { |k, v| k.name + ':' + v.size.to_s }.join(', ')} in: #{Time.now - now}"
      end

      static.each do |route|
        # recompute bitfields of passed-in routes since the bits may have changed across auto-router runs
        route.bitfield = bitfield_from_connection(route.connection_data, hexside_bits)
        train_routes[route.train] = [route] # force this train's route to be the passed-in one
      end

      train_routes.each do |train, routes|
        train_routes[train] = routes.sort_by(&:revenue).reverse.take(route_limit)
      end

      [train_routes, path_walk_timed_out]
    end

    def compute_for_train_group(trains, corporation, **opts)
      route_timeout = opts[:route_timeout] || 10

      train_routes, path_walk_timed_out = path(trains, corporation, **opts)
      sorted_routes = train_routes.map { |_train, routes| routes }

      limit = sorted_routes.map(&:size).reduce(&:*)
      LOGGER.debug do
        "Finding route combos of best #{train_routes.map { |k, v| k.name + ':' + v.size.to_s }.join(', ')} "\
          "routes with depth #{limit}"
      end

      now = Time.now
      possibilities = js_evaluate_combos(sorted_routes, route_timeout)

      if path_walk_timed_out
        @flash&.call('Auto route path walk failed to complete (PATH TIMEOUT)')
      elsif Time.now - now > route_timeout
        @flash&.call('Auto route selection failed to complete (ROUTE TIMEOUT)')
      end

      # final sanity check on best combos: recompute each route.revenue in case it needs to reject a combo
      max_routes = possibilities.max_by do |routes|
        routes.each do |route|
          route.clear_cache!(only_routes: true)
          route.routes = routes
          route.revenue
        end
        @game.routes_revenue(routes)
      rescue GameError => e
        # report error but still include combo with errored route in the result set
        LOGGER.debug { " Sanity check error, likely an auto_router bug: #{e}" }
        routes
      end || []

      max_routes.each { |route| route.routes = max_routes }
    end

    # inputs:
    #   connection is a route's connection_data
    #   hexside_bits is a map of hexside_id to bit number
    # returns:
    #   the bitfield (array of ints) representing all hexsides in the connection path
    # updates:
    #   new hexsides are added to hexside_bits
    def bitfield_from_connection(connection, hexside_bits)
      bitfield = [0]
      connection.each do |conn|
        paths = conn[:chain][:paths]
        if paths.size == 1 # special case for tiny intra-tile path like in 18NewEngland (issue #6890)
          hexside_left = paths[0].nodes[0].id
          check_edge_and_set(bitfield, hexside_left, hexside_bits)
          if paths[0].nodes.size > 1 # local trains may not have a second node
            hexside_right = paths[0].nodes[1].id
            check_edge_and_set(bitfield, hexside_right, hexside_bits)
          end
        else
          (paths.size - 1).times do |index|
            # hand-optimized ruby gives faster opal code
            node1 = paths[index]
            node2 = paths[index + 1]
            case node1.edges.size
            when 1
              # node1 has 1 edge, connect it to first edge of node2
              hexside_left = node1.edges[0].id
              hexside_right = node2.edges[0].id
              check_and_set(bitfield, hexside_left, hexside_right, hexside_bits)
            when 2
              # node1 has 2 edges, connect them as well as 2nd edge to first node2 edge
              hexside_left = node1.edges[0].id
              hexside_right = node1.edges[1].id
              check_and_set(bitfield, hexside_left, hexside_right, hexside_bits)
              hexside_left = hexside_right
              hexside_right  = node2.edges[0].id
              check_and_set(bitfield, hexside_left, hexside_right, hexside_bits)
            else
              LOGGER.debug "  ERROR: auto-router found unexpected number of path node edges #{node1.edges.size}. "\
                           'Route combos may be be incorrect'
            end
          end
        end
      end
      bitfield
    end

    def check_and_set(bitfield, hexside_left, hexside_right, hexside_bits)
      check_edge_and_set(bitfield, hexside_left, hexside_bits)
      check_edge_and_set(bitfield, hexside_right, hexside_bits)
    end

    def check_edge_and_set(bitfield, hexside_edge, hexside_bits)
      if hexside_bits.include?(hexside_edge)
        set_bit(bitfield, hexside_bits[hexside_edge])
      else
        hexside_bits[hexside_edge] = @next_hexside_bit
        set_bit(bitfield, @next_hexside_bit)
        @next_hexside_bit += 1
      end
    end

    # bitfield is an array of integers, can be expanded by this call if necessary
    # bit is a bit number, 0 is lowest bit, 32 will jump to the next int in the array, and so on
    def set_bit(bitfield, bit)
      entry = (bit / 32).to_i
      mask = 1 << (bit & 31)
      add_count = entry + 1 - bitfield.size
      while add_count.positive?
        bitfield << 0
        add_count -= 1
      end
      bitfield[entry] |= mask
    end

    # The js-in-Opal algorithm
    def js_evaluate_combos(_rb_sorted_routes, _route_timeout)
      rb_possibilities = []
      possibilities_count = 0
      conflicts = 0
      now = Time.now

      %x{
        let possibilities = []
        let combos = []
        let counter = 0
        let max_revenue = 0
        let js_now = Date.now()
        let js_route_timeout = _route_timeout * 1000

        // marshal Opal objects to js for faster/easier access
        const js_sorted_routes = []
        let limit = 1
        Opal.send(_rb_sorted_routes, 'each', [], function(rb_routes) {
          let js_routes = []
          limit *= rb_routes.length
          Opal.send(rb_routes, 'each', [], function(rb_route)
          {
            js_routes.push( { route: rb_route, bitfield: rb_route.bitfield, revenue: rb_route.revenue } )
          })
          js_sorted_routes.push(js_routes)
        })
        let old_limit = limit

        // init combos with first train's routes
        for (r=0; r < js_sorted_routes[0].length; r++) {
          const route = js_sorted_routes[0][r]
          counter += 1
          combo = { revenue: route.revenue, routes: [route] }
          combos.push(combo) // save combo for later extension even if not yet a valid combo

          if (is_valid_combo(combo))
          {
            possibilities_count += 1

            // accumulate best-value combos, or start over if found a bigger best
            if (combo.revenue >= max_revenue) {
              if (combo.revenue > max_revenue) {
                possibilities = []
                max_revenue = combo.revenue
              }
              possibilities.push(combo)
            }
          }
        }

        continue_looking = true
        // generate combos with remaining trains' routes
        for (let train=1; continue_looking && (train < js_sorted_routes.length); train++) {
          // Recompute limit, since by 3rd train it will start going down as invalid combos are excluded from the test set
          // revised limit = combos.length * remaining train route lengths
          limit = combos.length
          for (let remaining=train; remaining < js_sorted_routes.length; remaining++)
            limit *= js_sorted_routes[remaining].length
          if (limit != old_limit) {
            console.log("  adjusting depth to " + limit + " because first " +
                        train + " trains only had " + combos.length + " valid combos")
            old_limit = limit
          }

          let new_combos = []
          for (let rt=0; continue_looking && (rt < js_sorted_routes[train].length); rt++) {
            const route = js_sorted_routes[train][rt]
            for (let c=0; c < combos.length; c++) {
              const combo = combos[c]
              counter += 1
              if ((counter % 1_000_000) == 0) {
                console.log(counter + " / " + limit)
                if (Date.now() - js_now > js_route_timeout) {
                  console.log("Route timeout reached")
                  continue_looking = false
                  break
                }
              }

              if (js_route_bitfield_conflicts(combo, route))
                conflicts += 1
              else {
                // copy the combo, add the route
                let newcombo = { revenue: combo.revenue, routes: [...combo.routes] }
                newcombo.routes.push(route)
                newcombo.revenue += route.revenue
                new_combos.push(newcombo) // save newcombo for later extension even if not yet a valid combo

                if (is_valid_combo(newcombo)) {
                  possibilities_count += 1

                  // accumulate best-value combos, or start over if found a bigger best
                  if (newcombo.revenue >= max_revenue) {
                    if (newcombo.revenue > max_revenue) {
                      possibilities = []
                      max_revenue = newcombo.revenue
                    }
                    possibilities.push(newcombo)
                  }
                }
              }
            }
          }
          new_combos.forEach((combo, n) => { combos.push(combo) })
        }

        // marshall best combos back to Opal
        for (let p=0; p < possibilities.length; p++) {
          const combo = possibilities[p]
          let rb_routes = []
          for (route of combo.routes) {
            rb_routes['$<<'](route.route)
          }
          rb_possibilities['$<<'](rb_routes)
        }
      }

      LOGGER.debug do
        "Found #{possibilities_count} possible combos (#{rb_possibilities.size} best) and rejected #{conflicts} "\
          "conflicting combos in: #{Time.now - now}"
      end
      rb_possibilities
    end

    %x{
      // do final combo validation using game-specific checks driven by
      // route.check_other! that was skipped when building routes
      function is_valid_combo(cb) {
        // temporarily marshall back to opal since we need to call the opal route.check_other!
        let rb_rts = []
        for (let rt of cb.routes) {
          rt.route['$routes='](rb_rts) // allows route.check_other! to process all routes
          rb_rts['$<<'](rt.route)
        }

        // Run route.check_other! for the full combo, to see if game- and action-specific rules are followed.
        // Eg. 1870 destination runs should reject combos that don't have a route from home to destination city
        try {
          for (let rt of cb.routes) {
            rt.route['$check_other!']() // throws if bad combo
          }
          return true
        }
        catch (err) {
          return false
        }
      }

      function js_route_bitfield_conflicts(combo, testroute) {
        for (let cr of combo.routes) {
          // each route has 1 or more ints in bitfield array
          // only test up to the shorter size, since bits beyond that obviously don't conflict
          let index = Math.min(cr.bitfield.length, testroute.bitfield.length) - 1;
          while (index >= 0) {
            if ((cr.bitfield[index] & testroute.bitfield[index]) != 0)
              return true
            index -= 1
          }
        }
        return false
      }

      function estimate_revenue(router, routes, routes_metadata) {
        // This is just a quick example of optimizations we can apply here.
        // Calling back into ruby is expensive, so we try to estimate in js the
        // upper bound of revenue and if the combo of routes are valid.

        // This is just the "routes can't overlap" optimization using an opt
        // out. An opt in would probably be safer, but the old autorouter always
        // assumes it's valid, so this is no worse. Once we figure out how to configure
        // the auto router per game, we should change this.

        const opt_fails_overlap = {
          1822: true,
          1860: true,
          1862: true,
          "18 Los Angeles 2": true,
        };
        if (!opt_fails_overlap[router.title] && routes_metadata.overlap) {
          return -1;
        }
        return routes_metadata.estimate_revenue;
      }


      function is_worth_adding_trains(router, routes, routes_metadata, next_routes) {
        // TODO: I wonder if it's always true that revenue is less than
        // or equal to the sum of the revenues of trains individually
        return (
          routes_metadata.estimate_revenue +
            next_routes.max_possible_revenue_for_rest_of_trains >
            router.best_revenue_so_far
        );
      }

      function add_train_to_routes_metadata(
        selected_routes,
        route,
        selected_routes_metadata,
      ) {
        return {
          estimate_revenue:
            selected_routes_metadata.estimate_revenue + route.estimate_revenue,
          bitfield: js_route_bitfield_merge(
            route.bitfield,
            selected_routes_metadata.bitfield,
          ),
          overlap:
            selected_routes_metadata.overlap ||
            new_js_route_bitfield_conflicts(
              route.bitfield,
              selected_routes_metadata.bitfield,
            ),
        };
      }

      function get_empty_metadata() {
        return {
          estimate_revenue: 0,
          bitfield: [],
          overlap: false,
        };
      }

      let start_of_execution_tick = 0;
      let start_of_all = 0;
      function next_frame() {
        return new Promise(resolve => requestAnimationFrame(resolve));
      }


      async function new_autoroute(router, trains_to_routes_map) {
        start_of_all = start_of_execution_tick = performance.now();
        router.title = router.game.$meta().$title();
        router.best_revenue_so_far = 0; // the best revenue we have found for a valid set of trains
        router.best_routes = []; // the best set of routes
        let trains_to_routes = Array.from(trains_to_routes_map).map(
          ([train, routes]) => routes,
        );

        for (let i = 0; i < trains_to_routes.length; ++i) {
          for (let j = 0; j < trains_to_routes[i].length; ++j) {
            trains_to_routes[i][j].estimate_revenue = trains_to_routes[i][j].revenue;
          }
        }
        let next_routes = null;
        trains_to_routes.forEach((routes) => {
          let r = next_routes
            ? next_routes.max_possible_revenue_for_rest_of_trains
            : 0;
          r += routes[0].estimate_revenue;
          next_routes = {
            routes,
            max_possible_revenue_for_rest_of_trains: r,
            next: next_routes,
          };
        });
        await find_best_combo(router, [], get_empty_metadata(), next_routes);

        return router.best_routes;
      }

      // selected_routes : [Route] -- the subset of trains we are exploring and will expand on
      // selected_routes_metadata : a bag of information to make searching faster. Example things: revenue of selected routes and bitset of trains routes
      // next_routes : ?{ routes: [Route], max_possible_revenue_for_rest_of_trains: int,  next: NextRoutes}. This is basically a recursive data structure where we have a layer per train
      async function find_best_combo(
        router,
        selected_routes,
        selected_routes_metadata,
        next_routes,
      ) {
        for (let route of next_routes.routes) {
          if (performance.now() - start_of_execution_tick > 30) {
            if (router.render) {
                router.$real_revenue(router.best_routes)
                g_update(router.best_routes)
            }
            await next_frame();
            if (!router.running) {
              return;
            }
            start_of_execution_tick = performance.now();
          }
          let current_routes_metadata = add_train_to_routes_metadata(
            selected_routes,
            route,
            selected_routes_metadata,
          );
          // TODO: We probably will want to avoid the array copy for performance, but this is easier to understand for now
          let current_routes = [...selected_routes, route];

          // check if this new subset is the new best route
          let estimate = estimate_revenue(router, current_routes, current_routes_metadata);
          if (estimate > router.best_revenue_so_far) {
            let revenue = router.$real_revenue(current_routes);
            if (revenue > router.best_revenue_so_far) {
              router.best_revenue_so_far = revenue;
              router.best_routes = current_routes.map((r) => r.$clone());
              router.render = true;
            }
          }

          // if we have more routes to check
          if (next_routes.next !== null) {
          // first check without this train, so we don't get
            // stuck with duplicate routes with 100% overlap on 1862 type maps as the suggested routes
            await find_best_combo(
              router,
              selected_routes,
              selected_routes_metadata,
              next_routes.next,
            );

            // if we have another train to search for routes, check if it's worth exploring and if so, explore!
            if (
              is_worth_adding_trains(
                router,
                current_routes,
                current_routes_metadata,
                next_routes.next,
              )
            ) {
              await find_best_combo(
                router,
                current_routes,
                current_routes_metadata,
                next_routes.next,
              );
            } else if (next_routes.next != null) {
              console.log("skipping");
            }
          }
        }
      }

      function new_js_route_bitfield_conflicts(a, b) {
        let index = Math.min(a.length, b.length) - 1;
        while (index >= 0) {
          if ((a[index] & b[index]) != 0) return true;
          index -= 1;
        }
        return false;
      }

      function js_route_bitfield_merge(a, b) {
        let max = Math.max(a.length, b.length);
        let result = [];
        for (let i = 0; i < max; ++i) {
          result.push((a[i] ?? 0) | (b[i] ?? 0));
        }
        return result;
      }
    }
  end
end
