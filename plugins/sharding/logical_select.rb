module Groonga
  module Sharding
    class LogicalSelectCommand < Command
      register("logical_select",
               [
                 "logical_table",
                 "shard_key",
                 "min",
                 "min_border",
                 "max",
                 "max_border",
                 "filter",
                 "sortby",
                 "output_columns",
                 "offset",
                 "limit",
                 "drilldown",
                 "drilldown_sortby",
                 "drilldown_output_columns",
                 "drilldown_offset",
                 "drilldown_limit",
                 "drilldown_calc_types",
                 "drilldown_calc_target",
               ])

      def run_body(input)
        enumerator = LogicalEnumerator.new("logical_select", input)

        context = ExecuteContext.new(input)
        begin
          executor = Executor.new(context)
          executor.execute

          n_results = 1
          n_plain_drilldowns = context.plain_drilldown.n_result_sets
          n_labeled_drilldowns = context.labeled_drilldowns.n_result_sets
          if n_plain_drilldowns > 0
            n_results += n_plain_drilldowns
          elsif
            if n_labeled_drilldowns > 0
              n_results += 1
            end
          end

          writer.array("RESULT", n_results) do
            write_records(writer, context)
            if n_plain_drilldowns > 0
              write_plain_drilldowns(writer, context)
            elsif n_labeled_drilldowns > 0
              write_labeled_drilldowns(writer, context)
            end
          end
        ensure
          context.close
        end
      end

      private
      def cache_key(input)
        key = "logical_select\0"
        key << "#{input[:logical_table]}\0"
        key << "#{input[:shard_key]}\0"
        key << "#{input[:min]}\0"
        key << "#{input[:min_border]}\0"
        key << "#{input[:max]}\0"
        key << "#{input[:max_border]}\0"
        key << "#{input[:filter]}\0"
        key << "#{input[:sortby]}\0"
        key << "#{input[:output_columns]}\0"
        key << "#{input[:offset]}\0"
        key << "#{input[:limit]}\0"
        key << "#{input[:drilldown]}\0"
        key << "#{input[:drilldown_sortby]}\0"
        key << "#{input[:drilldown_output_columns]}\0"
        key << "#{input[:drilldown_offset]}\0"
        key << "#{input[:drilldown_limit]}\0"
        key << "#{input[:drilldown_calc_types]}\0"
        key << "#{input[:drilldown_calc_target]}\0"
        labeled_drilldowns = LabeledDrilldowns.parse(input).sort_by(&:label)
        labeled_drilldowns.each do |drilldown|
          key << "#{drilldown.label}\0"
          key << "#{drilldown.keys.join(',')}\0"
          key << "#{drilldown.output_columns}\0"
          key << "#{drilldown.offset}\0"
          key << "#{drilldown.limit}\0"
          key << "#{drilldown.calc_types}\0"
          key << "#{drilldown.calc_target_name}\0"
        end
        key
      end

      def write_records(writer, context)
        result_sets = context.result_sets

        n_hits = 0
        n_elements = 2 # for N hits and columns
        result_sets.each do |result_set|
          n_hits += result_set.size
          n_elements += result_set.size
        end

        output_columns = context.output_columns

        writer.array("RESULTSET", n_elements) do
          writer.array("NHITS", 1) do
            writer.write(n_hits)
          end
          first_result_set = result_sets.first
          if first_result_set
            writer.write_table_columns(first_result_set, output_columns)
          end

          current_offset = context.offset
          current_offset += n_hits if current_offset < 0
          current_limit = context.limit
          current_limit += n_hits + 1 if current_limit < 0
          options = {
            :offset => current_offset,
            :limit => current_limit,
          }
          result_sets.each do |result_set|
            if result_set.size > current_offset
              writer.write_table_records(result_set, output_columns, options)
            end
            if current_offset > 0
              current_offset = [current_offset - result_set.size, 0].max
            end
            current_limit -= result_set.size
            break if current_limit <= 0
            options[:offset] = current_offset
            options[:limit] = current_limit
          end
        end
      end

      def write_plain_drilldowns(writer, execute_context)
        plain_drilldown = execute_context.plain_drilldown

        drilldowns = plain_drilldown.result_sets
        output_columns = plain_drilldown.output_columns
        options = {
          :offset => plain_drilldown.offset,
          :limit  => plain_drilldown.limit,
        }

        drilldowns.each do |drilldown|
          n_elements = 2 # for N hits and columns
          n_elements += drilldown.size
          writer.array("RESULTSET", n_elements) do
            writer.array("NHITS", 1) do
              writer.write(drilldown.size)
            end
            writer.write_table_columns(drilldown, output_columns)
            writer.write_table_records(drilldown, output_columns,
                                       options)
          end
        end
      end

      def write_labeled_drilldowns(writer, execute_context)
        labeled_drilldowns = execute_context.labeled_drilldowns
        is_command_version1 = (context.command_version == 1)

        writer.map("DRILLDOWNS", labeled_drilldowns.n_result_sets) do
          labeled_drilldowns.each do |drilldown|
            writer.write(drilldown.label)

            result_set = drilldown.result_set
            n_elements = 2 # for N hits and columns
            n_elements += result_set.size
            output_columns = drilldown.output_columns
            options = {
              :offset => drilldown.offset,
              :limit  => drilldown.limit,
            }

            writer.array("RESULTSET", n_elements) do
              writer.array("NHITS", 1) do
                writer.write(result_set.size)
              end
              writer.write_table_columns(result_set, output_columns)
              if is_command_version1 and drilldown.need_command_version2?
                context.with_command_version(2) do
                  writer.write_table_records(result_set,
                                             drilldown.output_columns_v2,
                                             options)
                end
              else
                writer.write_table_records(result_set, output_columns, options)
              end
            end
          end
        end
      end

      module KeysParsable
        private
        def parse_keys(raw_keys)
          return [] if raw_keys.nil?

          raw_keys.strip.split(/ *, */)
        end
      end

      module Calculatable
        def calc_target(table)
          return nil if @calc_target_name.nil?
          table.find_column(@calc_target_name)
        end

        private
        def parse_calc_types(raw_types)
          return TableGroupFlags::CALC_COUNT if raw_types.nil?

          types = 0
          raw_types.strip.split(/ *, */).each do |name|
            case name
            when "COUNT"
              types |= TableGroupFlags::CALC_COUNT
            when "MAX"
              types |= TableGroupFlags::CALC_MAX
            when "MIN"
              types |= TableGroupFlags::CALC_MIN
            when "SUM"
              types |= TableGroupFlags::CALC_SUM
            when "AVG"
              types |= TableGroupFlags::CALC_AVG
            when "NONE"
              # Do nothing
            else
              raise InvalidArgument, "invalid drilldown calc type: <#{name}>"
            end
          end
          types
        end
      end

      class ExecuteContext
        include KeysParsable

        attr_reader :enumerator
        attr_reader :filter
        attr_reader :offset
        attr_reader :limit
        attr_reader :sort_keys
        attr_reader :output_columns
        attr_reader :result_sets
        attr_reader :unsorted_result_sets
        attr_reader :plain_drilldown
        attr_reader :labeled_drilldowns
        def initialize(input)
          @input = input
          @enumerator = LogicalEnumerator.new("logical_select", @input)
          @filter = @input[:filter]
          @offset = (@input[:offset] || 0).to_i
          @limit = (@input[:limit] || 10).to_i
          @sort_keys = parse_keys(@input[:sortby])
          @output_columns = @input[:output_columns] || "_id, _key, *"

          @result_sets = []
          @unsorted_result_sets = []

          @plain_drilldown = PlainDrilldownExecuteContext.new(@input)
          @labeled_drilldowns = LabeledDrilldowns.parse(@input)
        end

        def close
          @result_sets.each do |result_set|
            result_set.close if result_set.temporary?
          end
          @unsorted_result_sets.each do |result_set|
            result_set.close if result_set.temporary?
          end

          @plain_drilldown.close
          @labeled_drilldowns.close
        end
      end

      class PlainDrilldownExecuteContext
        include KeysParsable
        include Calculatable

        attr_reader :keys
        attr_reader :offset
        attr_reader :limit
        attr_reader :sort_keys
        attr_reader :output_columns
        attr_reader :calc_target_name
        attr_reader :calc_types
        attr_reader :result_sets
        attr_reader :unsorted_result_sets
        def initialize(input)
          @input = input
          @keys = parse_keys(@input[:drilldown])
          @offset = (@input[:drilldown_offset] || 0).to_i
          @limit = (@input[:drilldown_limit] || 10).to_i
          @sort_keys = parse_keys(@input[:drilldown_sortby])
          @output_columns = @input[:drilldown_output_columns]
          @output_columns ||= "_key, _nsubrecs"
          @calc_target_name = @input[:drilldown_calc_target]
          @calc_types = parse_calc_types(@input[:drilldown_calc_types])

          @result_sets = []
          @unsorted_result_sets = []
        end

        def close
          @result_sets.each do |result_set|
            result_set.close
          end
          @unsorted_result_sets.each do |result_set|
            result_set.close
          end
        end

        def have_keys?
          @keys.size > 0
        end

        def n_result_sets
          @result_sets.size
        end
      end

      class LabeledDrilldowns
        include Enumerable

        class << self
          def parse(input)
            drilldowns = {}
            arguments = input.arguments
            argument = Record.new(arguments, nil)
            arguments.each do |argument_id|
              argument.id = argument_id
              key = argument.key
              match_data = /\Adrilldown\[(.+?)\]\.(.+)\z/.match(key)
              next if match_data.nil?
              drilldown = (drilldowns[match_data[1]] ||= {})
              drilldown[match_data[2]] = input[key]
            end

            contexts = []
            drilldowns.each do |label, parameters|
              next if parameters["keys"].nil?
              contexts << LabeledDrilldownExecuteContext.new(label, parameters)
            end
            return nil if contexts.nil?

            new(contexts)
          end
        end

        def initialize(contexts)
          @contexts = contexts
        end

        def close
          @contexts.each do |context|
            context.close
          end
        end

        def have_keys?
          @contexts.size > 0
        end

        def n_result_sets
          @contexts.size
        end

        def each(&block)
          @contexts.each(&block)
        end
      end

      class LabeledDrilldownExecuteContext
        include KeysParsable
        include Calculatable

        attr_reader :label
        attr_reader :keys
        attr_reader :offset
        attr_reader :limit
        attr_reader :sort_keys
        attr_reader :output_columns
        attr_reader :calc_target_name
        attr_reader :calc_types
        attr_accessor :result_set
        attr_accessor :unsorted_result_set
        def initialize(label, parameters)
          @label = label
          @keys = parse_keys(parameters["keys"])
          @offset = (parameters["offset"] || 0).to_i
          @limit = (parameters["limit"] || 10).to_i
          @sort_keys = parse_keys(parameters["sortby"])
          @output_columns = parameters["output_columns"]
          @output_columns ||= "_key, _nsubrecs"
          @calc_target_name = parameters["calc_target"]
          @calc_types = parse_calc_types(parameters["calc_types"])

          @result_set = nil
          @unsorted_result_set = nil
        end

        def close
          @result_set.close if @result_set
          @unsorted_result_set.close if @unsored_result_set
        end

        def need_command_version2?
          /[.\[]/ === @output_columns
        end

        def output_columns_v2
          columns = @output_columns.strip.split(/ *, */)
          converted_columns = columns.collect do |column|
            match_data = /\A_value\.(.+)\z/.match(column)
            if match_data.nil?
              column
            else
              nth_key = keys.index(match_data[1])
              if nth_key
                "_key[#{nth_key}]"
              else
                column
              end
            end
          end
          converted_columns.join(",")
        end
      end

      class Executor
        def initialize(context)
          @context = context
        end

        def execute
          execute_search
          if @context.plain_drilldown.have_keys?
            execute_plain_drilldown
          elsif @context.labeled_drilldowns.have_keys?
            execute_labeled_drilldowns
          end
        end

        private
        def execute_search
          first_shard = nil
          enumerator = @context.enumerator
          enumerator.each do |shard, shard_range|
            first_shard ||= shard
            shard_executor = ShardExecutor.new(@context, shard, shard_range)
            shard_executor.execute
          end
          if first_shard.nil?
            message =
              "[logical_select] no shard exists: " +
              "logical_table: <#{enumerator.logical_table}>: " +
              "shard_key: <#{enumerator.shard_key_name}>"
            raise InvalidArgument, message
          end
          if @context.result_sets.empty?
            result_set = HashTable.create(:flags => ObjectFlags::WITH_SUBREC,
                                          :key_type => first_shard.table)
            @context.result_sets << result_set
          end
        end

        def execute_plain_drilldown
          drilldown = @context.plain_drilldown
          group_result = TableGroupResult.new
          begin
            group_result.key_begin = 0
            group_result.key_end = 0
            group_result.limit = 1
            group_result.flags = drilldown.calc_types
            drilldown.keys.each do |key|
              @context.result_sets.each do |result_set|
                with_calc_target(group_result,
                                 drilldown.calc_target(result_set)) do
                  result_set.group([key], group_result)
                end
              end
              result_set = group_result.table
              if drilldown.sort_keys.empty?
                drilldown.result_sets << result_set
              else
                drilldown.result_sets << result_set.sort(drilldown.sort_keys)
                drilldown.unsorted_result_sets << result_set
              end
              group_result.table = nil
            end
          ensure
            group_result.close
          end
        end

        def execute_labeled_drilldowns
          drilldowns = @context.labeled_drilldowns

          drilldowns.each do |drilldown|
            group_result = TableGroupResult.new
            keys = drilldown.keys
            begin
              group_result.key_begin = 0
              group_result.key_end = keys.size - 1
              if keys.size > 1
                group_result.max_n_sub_records = 1
              end
              group_result.limit = 1
              group_result.flags = drilldown.calc_types
              @context.result_sets.each do |result_set|
                with_calc_target(group_result,
                                 drilldown.calc_target(result_set)) do
                  result_set.group(keys, group_result)
                end
              end
              result_set = group_result.table
              if drilldown.sort_keys.empty?
                drilldown.result_set = result_set
              else
                drilldown.result_set = result_set.sort(drilldown.sort_keys)
                drilldown.unsorted_result_set = result_set
              end
              group_result.table = nil
            ensure
              group_result.close
            end
          end
        end

        def with_calc_target(group_result, calc_target)
          group_result.calc_target = calc_target
          begin
            yield
          ensure
            calc_target.close if calc_target
            group_result.calc_target = nil
          end
        end
      end

      class ShardExecutor
        def initialize(context, shard, shard_range)
          @context = context
          @shard = shard
          @shard_range = shard_range

          @filter = @context.filter
          @sort_keys = @context.sort_keys
          @result_sets = @context.result_sets
          @unsorted_result_sets = @context.unsorted_result_sets

          @target_range = @context.enumerator.target_range

          @cover_type = @target_range.cover_type(@shard_range)
        end

        def execute
          return if @cover_type == :none
          return if @shard.table.empty?

          shard_key = @shard.key
          if shard_key.nil?
            message = "[logical_select] shard_key doesn't exist: " +
                      "<#{@shard.key_name}>"
            raise InvalidArgument, message
          end

          expression_builder = RangeExpressionBuilder.new(shard_key,
                                                          @target_range,
                                                          @filter)
          case @cover_type
          when :all
            filter_shard_all(expression_builder)
          when :partial_min
            filter_table do |expression|
              expression_builder.build_partial_min(expression)
            end
          when :partial_max
            filter_table do |expression|
              expression_builder.build_partial_max(expression)
            end
          when :partial_min_and_max
            filter_table do |expression|
              expression_builder.build_partial_min_and_max(expression)
            end
          end
        end

        private
        def filter_shard_all(expression_builder)
          if @filter.nil?
            add_result_set(@shard.table)
          else
            filter_table do |expression|
              expression_builder.build_all(expression)
            end
          end
        end

        def create_expression(table)
          expression = Expression.create(table)
          begin
            yield(expression)
          ensure
            expression.close
          end
        end

        def filter_table
          table = @shard.table
          create_expression(table) do |expression|
            yield(expression)
            add_result_set(table.select(expression))
          end
        end

        def add_result_set(result_set)
          return if result_set.empty?

          if @sort_keys.empty?
            @result_sets << result_set
          else
            @unsorted_result_sets << result_set
            sorted_result_set = result_set.sort(@sort_keys)
            @result_sets << sorted_result_set
          end
        end
      end
    end
  end
end
