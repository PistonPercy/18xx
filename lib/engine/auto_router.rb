# frozen_string_literal: true

# backtick_javascript: true

require_relative 'game_error'
require_relative 'route'

module Engine
  class AutoRouter
    attr_accessor :running

    def initialize(game, flash = nil)
      @game = game
      @train_autoroute_group = @game.class::TRAIN_AUTOROUTE_GROUPS
      @next_hexside_bit = 0
      @flash = flash
      @chains = {}
    end

    def compute(corporation, **opts)
      @running = true
      @route_timeout = opts[:route_timeout] || 10
      trains = @game.route_trains(corporation).sort_by(&:price)
      train_routes, path_walk_timed_out = path(trains, corporation, **opts)
      @flash&.call('Auto route path walk failed to complete (PATH TIMEOUT)') if path_walk_timed_out
      route(train_routes, opts[:callback])
    end

    def route(trains_to_routes, callback)
      %x{
        (new Autorouter(#{self}, #{trains_to_routes}, #{callback})).autoroute();
      }
    end

    def real_revenue(routes)
      routes.each do |route|
        route.clear_cache!(only_routes: true)
        route.routes = routes
        route.revenue
      end
      @game.routes_revenue(routes)
    rescue GameError
      -1
    end

    def path(trains, corporation, **opts)
      static = opts[:routes] || []
      path_timeout = 10
      route_limit = opts[:route_limit] || 10_000

      connections = {}

      graph = @game.graph_for_entity(corporation)
      tokened_nodes = graph.connected_nodes(corporation).keys.filter { |n| n.tokened_by?(corporation) }

      path_walk_timed_out = false
      now = Time.now

      skip_paths = [0]
      modify_bitfield_from_paths(skip_paths, static.flat_map(&:paths))
      # if only routing for subset of trains, omit the trains we won't assemble routes for
      skip_trains = static.flat_map(:train).to_a
      trains -= skip_trains

      train_routes = Hash.new { |h, k| h[k] = [] }    # map of train to route list
      @hexside_bits = Hash.new { |h, k| h[k] = 0 }     # map of hexside_id to bit number
      @next_hexside_bit = 0

      paths_walked_of_len = Hash.new { |h, k| h[k] = 0 }
      all_exception_count = Hash.new { |h, k| h[k] = 0 }
      overcounts = 0
      paths_yielded = 0
      route_counts = 0
      tokened_nodes.each do |node|
        if Time.now - now > path_timeout
          LOGGER.debug('Path timeout reached')
          path_walk_timed_out = true
          break
        else
          #LOGGER.debug { "Path search: #{nodes.index(node)} / #{nodes.size} - paths starting from #{node.hex.name}" }
        end

        walk_corporation = graph.no_blocking? ? nil : corporation

        walk_node_if_not_blocked = lambda do |visited_nodes, node, skip, ts, &block|
          if ts.nil?
            raise "no trains"
          end
          ret = block.call(visited_nodes, {}, [], ts, [])
          raise "abort found" if ret == :abort
          if ret != []
            if walk_corporation.nil? || !node.blocks?(walk_corporation)
              walk_via_chain(node, ret, corporation: walk_corporation, visited_nodes: visited_nodes, skip_paths: skip, &block)
            end
          end
          ret
        end

        node_walk_one_path = lambda do |node, trains, &block|
          all_paths = []
          node.paths.each do |path|
            path.walk do |path, vp|
              path.nodes.each do |inner_node|
                if inner_node != node
                  all_paths << { path_from_token_to_node: vp.keys, node: inner_node}
                end
              end
            end
          end

          # TODO: single node
          puts "do single paths for node #{node.hex.name}"
          walk_node_if_not_blocked.call([[node, true]].to_h, node, {}, trains) do |vn1, vp, visited_bitfield, ts, prebuilt_chain|
            if prebuilt_chain == []
              next ts
            else
              next block.call(ts, prebuilt_chain, visited_bitfield)
            end
          end

          for i in 0...all_paths.size-1
            for j in i+1...all_paths.size
              puts "doing paths #{i} and #{j} for node #{node.hex.name}"
              next if all_paths[i][:path_from_token_to_node].intersect?(all_paths[j][:path_from_token_to_node])
              skip_inner = skip_paths.clone
              modify_bitfield_from_paths(skip_inner, all_paths[i][:path_from_token_to_node])
              modify_bitfield_from_paths(skip_inner, all_paths[j][:path_from_token_to_node])
              middle_chain = [
                { nodes: [all_paths[j][:node], node], paths: all_paths[j][:path_from_token_to_node].reverse, hexes: all_paths[j][:path_from_token_to_node].reverse.map(&:hex) },
                { nodes: [node, all_paths[i][:node]], paths: all_paths[i][:path_from_token_to_node], hexes: all_paths[i][:path_from_token_to_node].map(&:hex) },]
              part2 = reverse_chain(middle_chain)
              middle_bitfield = [0]
              modify_bitfield_from_paths(middle_bitfield, all_paths[i][:path_from_token_to_node])
              modify_bitfield_from_paths(middle_bitfield, all_paths[j][:path_from_token_to_node])
              vn0 = [node, all_paths[i][:node], all_paths[j][:node]].map { |e| [e, true] }.to_h
              next if vn0.size != 3
              walk_node_if_not_blocked.call(vn0, all_paths[i][:node], skip_inner, trains) do |vn1, vp, visited_bitfield1, t1, prebuilt_chain1|
                skip_inner2 = `js_route_bitfield_merge`.call(skip_inner, visited_bitfield1)
                part1 = reverse_chain(prebuilt_chain1)
                first_bitfield = `js_route_bitfield_merge`.call(middle_bitfield, visited_bitfield1)
                ret = walk_node_if_not_blocked.call(vn1, all_paths[j][:node], skip_inner2, t1) do |vn2, vp2, visited_bitfield2, t2, prebuilt_chain2|
                  #puts "VISITED NODES 1: #{vn1.inspect} 2: #{vn2.inspect}"
                  part3 = prebuilt_chain2
                  #raise "missmatch1" if part1.size != 0 and (part1.last[:nodes][1] != part2[0][:nodes][0])
                  #raise "missmatch2" if part3.size != 0 and (part2.last[:nodes][1] != part3[0][:nodes][0])
                  #puts "inconsistent_chain" if part1.size > 1 and (part1.slice(0..-2).zip(part1.slice(1..-1)).filter { |x| x[0][:nodes][1] != x[1][:nodes][0] } != [])
                  #puts "inconsistent_chain" if part3.size > 1 and (part3.slice(0..-2).zip(part3.slice(1..-1)).filter { |x| x[0][:nodes][1] != x[1][:nodes][0] } != [])
                  next block.call(t2, part1 + part2 + part3, `js_route_bitfield_merge`.call(first_bitfield, visited_bitfield2))
                end

                next ret
              end
            end
          end

          # Don't allow future searches to enter this hex because we know all paths through this hex are fully explored
          modify_bitfield_from_paths(skip_paths, node.paths)
        end

        # TODO: .walk(corporation: walk_corporation, skip_paths: skip_paths
        #
        visit_count = 0
        node_walk_one_path.call(node, trains) do |ts, prebuilt_chain, bitfield_passed_in|
          paths_yielded += 1
          chains = prebuilt_chain
          # if we have an empty bitfield, just always check the route. this is basically for local trains with no path
          if bitfield_passed_in != [0] && connections[bitfield_passed_in]
            overcounts += 1
            next []
          end
          connections[bitfield_passed_in] = true

          connection = chains.map do |c|
            { left: c[:nodes][0], right: c[:nodes][1], chain: c }
          end


          # each train has opportunity to vote to abort a branch of this node's path-walk tree
          visit_count += 1
          if visit_count % 4096 == 0
            LOGGER.debug do
              "all exceptions: #{all_exception_count.map { |k, v| "#{k}: #{v}" }.join(', ')}"
            end
          end

          # build a test route for each train, use route.revenue to check for errors, keep the good ones
          next ts.filter  do |train|
            route = Engine::Route.new(
              @game,
              @game.phase,
              train,
              # we have to clone to prevent multiple routes having the same connection array.
              # If we don't clone, then later route.touch_node calls will affect all routes with
              # the same connection array
              connection_data: connection.clone,
              bitfield: bitfield_passed_in,
            )
            route.routes = [route]
            route_counts += 1
            # defer route combination checks until we have the full combination of routes to check
            route.revenue(suppress_check_route_combination: true)
            train_routes[train] << route
            true
          rescue RouteTooLong => e
            all_exception_count[:route_too_long] += 1
            # ignore for this train, and abort walking this path if ignored for all trains
            false
          rescue GameErrorInvalidRouteThatCantBeFixed => e
            all_exception_count[e.message] += 1
            false
          rescue ReusesCity
            puts "reuses city: #{route.revenue_str}"
            all_exception_count[:reuses_city] += 1
            false
            #TODO: next []
          rescue NoToken, RouteTooShort, GameError => e # rubocop:disable Lint/SuppressedException
            all_exception_count[e.message] += 1
            true
          end
        end
      end

      # Check that there are no duplicate hexside bits (algorithm error)
      LOGGER.debug do
        "Evaluated #{connections.size} paths, found #{@next_hexside_bit} unique hexsides, and found valid routes "\
          "#{train_routes.map { |k, v| k.name + ':' + v.size.to_s }.join(', ')} in: #{Time.now - now}"
      end
      LOGGER.debug do
        "Paths walked: #{paths_walked_of_len.map { |k, v| "#{k}: #{v}" }.join(', ')}"
      end
      LOGGER.debug do
        "Total Paths walked: #{paths_walked_of_len.values.sum}, "
      end
      LOGGER.debug do
        "all exceptions: #{all_exception_count.map { |k, v| "#{k}: #{v}" }.join(', ')}"
      end
      LOGGER.debug do
        "Overcount is #{overcounts}; route_counts is #{route_counts} paths_yielded is #{paths_yielded}"
      end

      static.each do |route|
        # recompute bitfields of passed-in routes since the bits may have changed across auto-router runs
        route.bitfield = bitfield_from_connection(route.connection_data)
        train_routes[route.train] = [route] # force this train's route to be the passed-in one
      end

      train_routes.each do |train, routes|
        train_routes[train] = routes.sort_by(&:revenue).reverse.take(route_limit)
      end

      [train_routes, path_walk_timed_out]
    end

    def single_path_to_string(path)
        "#{path.hex.name}-#{path.exits}"
    end

    def paths_to_string(paths)
      if !paths.empty? and single_path_to_string(paths[0]) > single_path_to_string(paths[-1])
        paths = paths.reverse()
      end

      paths.map do |path|
        "#{path.hex.name}-#{path.exits}"
      end.join('/')
    end

    def chains(node)
      @chains[node] ||= begin
        chains = []

        node.paths.each do |node_path|
          next if node_path.ignore?

          node_path.walk() do |path, vp, ct, converging|
            path.nodes.each do |next_node|
              next if next_node == node
              prebuilt_chain = { nodes: [node, next_node], paths: vp.keys, hexes: vp.keys.map(&:hex) }
              bitfield = [0]
              modify_bitfield_from_paths(bitfield, vp.keys)
              chains << [path, bitfield, next_node, prebuilt_chain]
            end
          end
        end

        chains
      end
    end

    def walk_via_chain(
      node,
      trains,
      corporation: nil,
      visited_nodes: {},
      prebuilt_chain: [],
      visited_bitfield: [0],
      skip_paths: [0],
      &block
    )
      # visited_nodes[self] = true # is this needed?

      chains(node).each do |path, chain_bitfield, nn, prebuilt_chain_part|
        #TODO does next [] == next?
        next [] if `js_route_bitfield_conflicts`.call(visited_bitfield, chain_bitfield)
        next [] if `js_route_bitfield_conflicts`.call(skip_paths, chain_bitfield)
        next [] if visited_nodes[nn]
        visited_bitfield2 = `js_route_bitfield_merge`.call(visited_bitfield, chain_bitfield)
        visited_nodes[nn] = true
        chains = prebuilt_chain + [prebuilt_chain_part]
        next_level_trains = yield visited_nodes, {}, visited_bitfield2, trains, chains
        # TODO can the path be terminal?
        if next_level_trains == [] || path.terminal? || (corporation && nn.blocks?(corporation))
          visited_nodes.delete(nn)
          next
        end


        walk_via_chain(
          nn,
          next_level_trains,
          prebuilt_chain: chains,
          corporation: corporation,
          visited_bitfield: visited_bitfield2,
          visited_nodes: visited_nodes,
          skip_paths: skip_paths,
          &block
        )
        visited_nodes.delete(nn)
      end
      #visited_nodes.delete(self)
    end

    # inputs:
    #   connection is a route's connection_data
    # returns:
    #   the bitfield (array of ints) representing all hexsides in the connection path
    def bitfield_from_connection(connection)
      bitfield = [0]
      connection.each do |conn|
        paths = conn[:chain][:paths]
        modify_bitfield_from_paths(bitfield, paths)
      end
      bitfield
    end

    def modify_bitfield_from_paths(bitfield, paths)
      if paths.size == 1 # special case for tiny intra-tile path like in 18NewEngland (issue #6890)
        hexside_left = paths[0].nodes[0].id
        check_edge_and_set(bitfield, hexside_left)
        if paths[0].nodes.size > 1 # local trains may not have a second node
          hexside_right = paths[0].nodes[1].id
          check_edge_and_set(bitfield, hexside_right)
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
            check_and_set(bitfield, hexside_left, hexside_right)
          when 2
            # node1 has 2 edges, connect them as well as 2nd edge to first node2 edge
            hexside_left = node1.edges[0].id
            hexside_right = node1.edges[1].id
            check_and_set(bitfield, hexside_left, hexside_right)
            hexside_left = hexside_right
            hexside_right  = node2.edges[0].id
            check_and_set(bitfield, hexside_left, hexside_right)
          else
            LOGGER.debug "  ERROR: auto-router found unexpected number of path node edges #{node1.edges.size}. "\
                         'Route combos may be be incorrect'
          end
        end
      end
    end

    def reverse_chain(chain)
      chain.reverse.map do |c| { nodes: c[:nodes].reverse, paths: c[:paths].reverse, hexes: c[:hexes].reverse } end
    end

    def check_and_set(bitfield, hexside_left, hexside_right)
      check_edge_and_set(bitfield, hexside_left)
      check_edge_and_set(bitfield, hexside_right)
    end

    def check_edge_and_set(bitfield, hexside_edge)
      if @hexside_bits.include?(hexside_edge)
        set_bit(bitfield, @hexside_bits[hexside_edge])
      else
        @hexside_bits[hexside_edge] = @next_hexside_bit
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

    %x{
      class Autorouter {
        constructor(router, trains_to_routes_map, update_callback) {
          this.router = router;
          this.trains_to_routes_map = trains_to_routes_map;
          this.update_callback = update_callback;
        }

        // Give an upper bound estimate for the revenue for the routes. Ideally, this is as tight as possible since it reduces
        // the number of calls to the real revenue function which is quite heavy. This returns -1 if the routes are invalid.
        estimate_revenue(routes_metadata) {
          if (routes_metadata.invalid_because_overlap) {
            return -1;
          }
          return routes_metadata.estimate_revenue;
        }


        // This is a heuristic to determine if we should continue exploring theroutes. If we have a route combo prefix that is
        // invalid and we know can't become true, we should return false here. Ideally we return false as often as possible since
        // this will prune the search space and make the autorouter faster.
        is_worth_adding_trains(routes, routes_metadata, current_train_data) {
          // If we hit an invalid overlap, we know we will always return -1 from estimate_revenue even if we add more trains, so
          // we can stop exploring this route combo prefix.
          if (routes_metadata.invalid_because_overlap) {
              return false;
          }

          // TODO: I wonder if it's always true that revenue is less than
          // or equal to the sum of the revenues of trains individually
          return (
            routes_metadata.estimate_revenue +
              current_train_data.max_possible_revenue_for_rest_of_trains >
              this.best_revenue_so_far
          );
        }

        // This is the helper function which does all the bookkeeping of metadata about the current route combo. It is likely
        // this will be extended with more fields if we add more hueristics
        add_train_to_routes_metadata(
          route,
          train_group,
          metadata,
        ) {
          let bitfield = [...metadata.bitfield];
          bitfield[train_group] = js_route_bitfield_merge(
              route.bitfield,
              bitfield[train_group],
          );
          return {
            estimate_revenue:
              metadata.estimate_revenue + route.estimate_revenue,
            bitfield,
            invalid_because_overlap:
              metadata.invalid_because_overlap ||
              js_route_bitfield_conflicts(
                route.bitfield,
                metadata.bitfield[train_group],
              ),
          };
        }

        // This is the base case metadata that should match the structure of add_train_to_routes_metadata
        get_empty_metadata(number_train_groups) {
          return {
            estimate_revenue: 0,
            bitfield: new Array(number_train_groups).fill(null).map(() => []),
            invalid_because_overlap: false,
          };
        }

        async autoroute() {
          this.start_of_all = this.start_of_execution_tick = performance.now();
          this.best_revenue_so_far = 0; // the best revenue we have found for a valid set of trains
          this.best_routes = []; // the best set of routes
          let trains_to_routes = Array.from(this.trains_to_routes_map).map(
            ([train, routes]) => [...routes, null], // add a null route to the end for the "no route for this train" case
          );

          if (trains_to_routes.length === 0) {
            this.router.running = false;
            this.update_callback([]);
            return;
          }

          for (let i = 0; i < trains_to_routes.length; ++i) {
            // the last route is the null route so skip it
            for (let j = 0; j < trains_to_routes[i].length - 1; ++j) {
              trains_to_routes[i][j].estimate_revenue = trains_to_routes[i][j].revenue;
            }
          }
          let train_data = null;
          let number_train_groups = 0;
          trains_to_routes.forEach((routes) => {
            let r = train_data
              ? train_data.max_possible_revenue_for_rest_of_trains
              : 0;
            r += routes[0].estimate_revenue;
            let train_group = 0;
            const game_group_rules = this.router.train_autoroute_group;
            if (game_group_rules == "each_train_separate") {
              train_group = number_train_groups;
              ++number_train_groups;
            } else if (Array.isArray(game_group_rules) && routes.length > 0) {
              const train_name = routes[0].$train().$name();
              train_group = game_group_rules.findIndex(group => group.includes(train_name)) + 1;
              number_train_groups = game_group_rules.length + 1;
            } else {
              number_train_groups = 1;
            }
            train_data = {
              routes,
              train_group,
              max_possible_revenue_for_rest_of_trains: r,
              next_train_data: train_data,
            };
          });
          this.find_best_combo([], this.get_empty_metadata(number_train_groups), train_data).then(() => {
            let best_routes = this.best_routes;
            // Fix up the revenue calculations since routes revenue can be
            // impacted by each other
            this.router.$real_revenue(best_routes)
            this.router.running = false
            Opal.LOGGER.$info("routing phase took " + (performance.now() - this.start_of_all) + "ms")
            this.update_callback(best_routes);
          }).catch((e) => {
            this.router.flash("Auto route selection failed to complete (" + e + ")");
            Opal.LOGGER.$error("routing phase failed with: " + e);
            Opal.LOGGER.$error(e.stack);
            this.router.running = false;
            this.update_callback([]);
          });
        }

        // This is the heavy recursive function which searches all combinations of routes per train. The high level view is that
        // the function recursively picks a route per train and checks if the route combo is better than the best route combo.
        // route_combo -- An array of routes that represents the prefix of selected routes per train
        // selected_routes_metadata : a bag of information to make searching faster which represents all the important
        //      information about the current route combo.
        // current_train_data : a bunch of information about the current train we are selecting a route for. This is a recursive
        //      data structure where we have a layer per train (.next_train_data).
        async find_best_combo(
          route_combo,
          starting_combo_metadata,
          current_train_data,
        ) {
          for (let route of current_train_data.routes) {
            await this.check_if_we_should_break();

            let current_routes_metadata = starting_combo_metadata;
            if (route) { // route is null for the "empty route"
              current_routes_metadata = this.add_train_to_routes_metadata(
                route,
                current_train_data.train_group,
                starting_combo_metadata,
              );
              route_combo.push(route);
            }

            // if we have selected a route for every train, let's evaluate the route combo
            if (current_train_data.next_train_data === null) {
              let estimate = this.estimate_revenue(current_routes_metadata);
              if (estimate > this.best_revenue_so_far) {
                let revenue = this.router.$real_revenue(route_combo);
                if (revenue > this.best_revenue_so_far) {
                  this.best_revenue_so_far = revenue;
                  this.best_routes = route_combo.map((r) => r.$clone());
                  this.render = true;
                }
              }
            // if we have more trains to pick routes for, check if it's worth exploring and if so, explore!
            } else if (this.is_worth_adding_trains(route_combo, current_routes_metadata, current_train_data.next_train_data)) {
              await this.find_best_combo(route_combo, current_routes_metadata, current_train_data.next_train_data);
            }

            if (route) { // "unselect" the route for this train
                console.assert(route_combo.pop() === route, "AutoRouter: popped wrong route");
            }
          }
        }

        // This is a helper function to check if we should break out of the autorouter loop and update the UI.
        async check_if_we_should_break() {
          if (performance.now() - this.start_of_execution_tick > 30) {
            if (this.render) {
                this.router.$real_revenue(this.best_routes)
                this.update_callback(this.best_routes)
                this.render = false;
            }
            if (performance.now() - this.start_of_all > this.router.route_timeout * 1000) {
                throw 'ROUTE_TIMEOUT';
            }
            await next_frame();
            if (!this.router.running) {
              return;
            }
            this.start_of_execution_tick = performance.now();
          }
        }
      }

      function js_route_bitfield_conflicts(a, b) {
        "use strict";
        let index = Math.min(a.length, b.length) - 1;
        while (index >= 0) {
          if ((a[index] & b[index]) != 0) return true;
          index -= 1;
        }
        return false;
      }

      function js_route_bitfield_merge(a, b) {
        "use strict";
        let max = Math.max(a.length, b.length);
        let result = [];
        for (let i = 0; i < max; ++i) {
          result.push((a[i] ?? 0) | (b[i] ?? 0));
        }
        return result;
      }

      function next_frame() {
        "use strict";
        return new Promise(resolve => requestAnimationFrame(resolve));
      }
    }
  end
end
