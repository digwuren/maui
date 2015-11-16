# encoding: UTF-8

require 'ostruct'
require 'rbconfig'
require 'set'
require 'stringio'

class ::String
  # Local enclosed variable for [[#to_xml]]
  char_entities = {
    '&' => '&amp;',
    '<' => '&lt;',
    '>' => '&gt;',
    '"' => '&quot;',
    "'" => '&apos;',
  }.freeze

  define_method :to_xml do ||
    return gsub(/[&<>'"]/){char_entities[$&]}
  end
end

module Fabricator
  RESOURCE_DIR = File.expand_path '../../res',
      File.dirname(__FILE__)
  class Vertical_Peeker
    def get_indented_lines_with_skip
      indent = nil; lines = []
      while peek_line =~ /^\s+/ or
          (peek_line == '' and
           !lines.empty? and
           peek_line(1) =~ /^\s+/) do
        # If the line ahead is not indented but we passed the
        # test, then [[get_line]] will return [[""]] and [[$&]]
        # is the _following_ line's indentation.
        indent = $&.length if indent.nil? or $&.length < indent
        lines.push get_line
      end
      return nil if lines.empty?
      lines.each{|l| l[0 ... indent] = ''}
      return OpenStruct.new(lines: lines, indent: indent)
    end

    def initialize port
      super()
      @port = port
      if @port.respond_to? :path then
        @filename = @port.path
      elsif @port == $stdin then
        @filename = '(stdin)'
      else
        @filename = '(unknown)'
      end
      @buffer = []
      @line_number = 1 # number of the first line in the buffer
      @eof_seen = false
      return
    end

    def peek_line ahead = 0
      raise 'invalid argument' unless ahead >= 0
      until @buffer.length > ahead or @eof_seen do
        line = @port.gets
        if line then
          line.rstrip!
          @buffer.push line
        else
          @eof_seen = true
        end
      end
      return @buffer[ahead] # nil if past eof
    end

    def get_line
      # ensure that if a line is available, it's in [[@buffer]]
      peek_line

      @line_number += 1 unless @buffer.empty?
      return @buffer.shift
    end

    def eof?
      return peek_line.nil?
    end

    def lineno_ahead
      return @line_number + (@line_consumed ? 1 : 0)
    end

    def location_ahead
      return OpenStruct.new(
        filename: @filename, line: lineno_ahead)
    end
  end

  class Integrator
    def check_root_type_consistency
      @output.roots.each do |name|
        cbn_entry = @output.chunks_by_name[name]
        effective_root_type = cbn_entry.root_type
        cbn_entry.headers.each do |element|
          unless element.root_type == effective_root_type then
            warn element.header_loc,
                "inconsistent root type, assuming %s" %
                    effective_root_type
          end
        end
      end
      return
    end

    attr_reader :output

    def initialize first_section: 1
      super()
      @output = OpenStruct.new(
        presentation: [], # list of titles and sections

        toc: [], # list of titles and rubrics.

        chunks_by_name: {},
            # canonical_name => OpenStruct
            #   root_type: String,
            #   chunks: list of :chunk/:diverted_chunk records,
            #   headers: list of :chunk/:divert records,

        roots: [], # list of canonical names

        warnings: [],

        index: {},
            # keyword => OpenStruct
            #   sort_key: string,
            #   canonical_representation: markup list,
            #   refs: [[number, reftype], ...],
      )
      @cursec = nil # The current section if started
      @first_section_number = first_section
      @section_count = 0 # The number of last section
      @title_counters = [0]
      @curdivert = nil # The current diversion if active
      @last_divertee = nil
          # last chunk diverted by [[@curdivert]]
      @list_stack = nil
      @in_code = false
      @last_title_level = 0
      @warning_counter = 0
      return
    end

    def integrate element
      if element.type == :title then
        # Check the title's level restriction
        if element.level > @last_title_level + 1 then
          warn element.loc, "title level too deep"
          element.level = @last_title_level + 1
        end
        @last_title_level = element.level

        # Number the title
        while @title_counters.length > element.level do
          @title_counters.pop
        end
        if @title_counters.length < element.level then
          @title_counters.push 0
        end
        @title_counters[-1] += 1
        element.number = @title_counters.join '.'

        # Append the node to [[presentation]] and [[toc]]
        force_section_break
        @output.presentation.push element
        @output.toc.push element

        # Enforce (sub(sub))chapter-locality of diversions
        clear_diversion
      else
        if element.type == :block and @curdivert then
          element.type = :diverted_chunk
          element.name = @curdivert.name
          element.divert = @curdivert

          element.initial = true if @last_divertee.nil?
          @last_divertee = element
        end
        if [:divert, :chunk].include? element.type then
          clear_diversion
        end
        if (@cursec and element.type == :rubric) or
            (@in_code and
                [:paragraph, :block, :item].include?(
                    element.type)) then
          (@cursec.warnings ||= []).push \
              warn(element.loc,
                  "silent section break",
                  inline: true)
          force_section_break
        end
        if @cursec.nil? then
          @cursec = OpenStruct.new(
            type: :section,
            section_number: @first_section_number +
                @section_count,
            elements: [],
            loc: element.loc)
            @section_count += 1
          @output.presentation.push @cursec
        end
        if element.type == :rubric then
          element.section_number = @cursec.section_number
          @output.toc.push element
        end
        if element.type == :divert then
          @curdivert = element
          raise 'assertion failed' unless @last_divertee.nil?
        end

        if element.type == :item then
          # Is this a top-level or descendant item?
          unless @list_stack then
            raise 'assertion failed' unless element.indent == 0

            # Create a new [[list]] node.
            new_list = OpenStruct.new(
              type: :list,
              items: [],
              indent: element.indent)
            @cursec.elements.push new_list
            @list_stack = [new_list]
          else
            while @list_stack.last.indent > element.indent do
              if @list_stack[-2].indent < element.indent then
                # Unexpected de-dent, like this:
                #    - master list
                #         - child 1
                #       - child 2
                @list_stack.last.indent = element.indent
                (element.warnings ||= []).push \
                    warn(element.loc,
                        "unexpected dedent", inline: true)
                break
              end
              @list_stack.pop
            end
            if @list_stack.last.indent < element.indent then
              if @list_stack.last.sublist then
                raise 'assertion failed'
              end
              new_list = OpenStruct.new(
                type: :list,
                items: [],
                indent: element.indent)
              @list_stack.last.items.last.sublist = new_list
              @list_stack.push new_list
            end
          end

          # The list structure has been prepared.  Append the
          # new element to the innermost list in progress.
          @list_stack.last.items.push element
        elsif element.type == :index_anchor then
          freeform_index_record(element.name).refs.push [
              @cursec.section_number, :manual]
        else
          @list_stack = nil
          @cursec.elements.push element
          if [:chunk, :diverted_chunk].
              include?(element.type) then
            element.section_number = @cursec.section_number
            element.content = []
            element.lines.each_with_index do
                |line, lineno_in_chunk|
              unless lineno_in_chunk.zero? then
                element.content.push \
                    OpenStruct.new(type: :newline)
              end
              column = 1 + element.indent
              line.split(/(<<\s*
                  (?:
                   \[\[.*?\]*\]\]
                   | .
                  )+?
                  \s*>>)/x, -1).each_with_index do
                    |raw_piece, piece_index|
                node = nil
                if piece_index.odd? then
                  name = raw_piece[2 ... -2].strip
                      # discard the surrounding double brokets
                      # together with adjacent whitespace
                  node = OpenStruct.new(type: :use,
                      name: nil,
                          # for ordering; will be replaced below
                      raw: raw_piece,
                      loc: OpenStruct.new(
                          filename: element.body_loc.filename,
                          line: element.body_loc.line +
                              lineno_in_chunk,
                          column: column)
                  )
                  if name =~ /(?:^|\s+)(\|[\w>-]+)$/ and
                      Fabricator::POSTPROCESSES.has_key? $1 then
                    node.postprocess = $1; name = $`
                  end
                  if name =~ /(?:^|\s+)(\.dense)$/ then
                    node.vertical_separation = $1; name = $`
                  end
                  if name =~ /^(\.clearindent)(?:\s+|$)/ then
                    node.clearindent = true; name = $'
                  end
                  if !name.empty? then
                    node.name =
                        Fabricator.canonicalise(name)
                  else
                    # not a proper reference, after all
                    node = nil
                  end
                  # If failed, [[node]] is still [[nil]].
                end
                if node.nil? and !raw_piece.empty? then
                  node = OpenStruct.new(
                    type: :verbatim,
                    data: raw_piece)
                end
                element.content.push node if node
                column += raw_piece.length
              end
            end
          end

          if [:chunk, :diverted_chunk, :divert].include?(
              element.type) then
            cbn_record =
                @output.chunks_by_name[element.name] ||=
                    OpenStruct.new(chunks: [], headers: [])

            # Do we have an explicit chunk header?
            if [:chunk, :divert].include? element.type then
              cbn_record.headers.push element
              if element.root_type then
                if !Fabricator.filename_sane? element.name then
                  (element.warnings ||= []).push \
                      warn(element.header_loc,
                          "unuseable filename",
                          inline: true)
                  element.root_type = nil
                end
              end
              if element.root_type and
                  cbn_record.root_type.nil? then
                cbn_record.root_type = element.root_type
                @output.roots.push element.name
              end
              if element.root_type == '.script' then
                cbn_record.root_type = element.root_type
              end
            end

            case element.type
              when :chunk then
                chunk_index_record(element.name).refs.push [
                    @cursec.section_number, :definition]

              when :divert then
                index_ref = [@cursec.section_number ..
                    @cursec.section_number, :definition]
                chunk_index_record(element.name).refs.push(
                    index_ref)
                # We'll add a pointer to this reference entry
                # into [[@curdivert]] so we can replace the
                # range later to cover all the sections in which
                # headerless chunks collected by this divert are
                # present.
                @curdivert.index_ref = index_ref

              when :diverted_chunk then
                prev_range = @curdivert.index_ref[0]
                @curdivert.index_ref[0] = prev_range.begin ..
                    @cursec.section_number
              else
                raise 'assertion failed'
            end

            # Do we have a chunk body?
            if [:chunk, :diverted_chunk].include?(
                element.type) then
              cbn_record.chunks.push element
              element.content.each do |node|
                next unless node.type == :use
                chunk_index_record(node.name).refs.push [
                    @cursec.section_number, :transclusion]
              end
            end
          end

          # If a chunk body is followed by a narrative-type
          # element, we'll want to generate an automatic section
          # break.
          if [:chunk, :diverted_chunk].
              include?(element.type) then
            @in_code = true
          end
        end
      end
      return
    end

    def chunk_index_record name
      identifier = "<< " +
          Fabricator.canonicalise(name) +
          " >>"
      markup = [OpenStruct.new(
          type: :mention_chunk,
          name: name)]
      return _index_record identifier, markup
    end

    def freeform_index_record name
      identifier = Fabricator.canonicalise(name)
      markup = Fabricator.parse_markup name,
              Fabricator::MF::LINK
      return _index_record identifier, markup
    end

    def _index_record identifier, markup
      return @output.index[identifier] ||=
          OpenStruct.new(
              sort_key: identifier.downcase.sub(
                  /^([^[:alnum:]]+)(.*)$/) {
                  $2 + ", " + $1},
              canonical_representation: markup,
              refs: [],
          )
    end

    def force_section_break
      if @cursec and @cursec.elements.empty? then
        # Section nodes are only created when there's at least one
        # element to be integrated.  This element may be an index
        # anchor, which is not actually added into the section's
        # [[elements]] list.  Since this is the only such case,
        # the meaning of [[elements]] being empty by the end of
        # the secion is unambiguous.
        (@cursec.warnings ||= []).push \
            warn(@cursec.loc,
                "section with index anchor(s) but no content",
                inline: true)
      end
      @cursec = nil
      @list_stack = nil
      @in_code = false
      return
    end

    def clear_diversion
      if @curdivert then
        if !@last_divertee then
          (@curdivert.warnings ||= []).push \
              warn(@curdivert.header_loc,
                  "unused diversion",
                  inline: true)
        elsif @last_divertee.initial then
          (@curdivert.warnings ||= []).push \
              warn(@curdivert.header_loc,
                  "single-use diversion",
                  inline: true)
        end
        @curdivert = nil
        @last_divertee.final = true if @last_divertee
        @last_divertee = nil
      end
      return
    end

    def in_list?
      return !@list_stack.nil?
    end

    def check_chunk_sizes limit
      return unless limit
      @output.presentation.each do |node|
        next unless node.type == :section
        node.elements.each do |element|
          next unless element.type == :chunk
          if element.lines.length > limit then
            if element.lines.length > limit * 2 then
              assessment, factor = "very long chunk", 2
            else
              assessment, factor = "long chunk", 1
            end
            limit_loc = element.body_loc.dup
            limit_loc.column = nil
            limit_loc.line += limit * factor
            (element.warnings ||= []).push \
                warn(limit_loc, "%s (%i lines)" %
                        [assessment, element.lines.length],
                    inline: true)
          end
        end
      end
      return
    end

    def warn location, message, inline: false
      record = OpenStruct.new(
        loc: location,
        message: message,
        number: @warning_counter += 1,
        inline: inline)
      @output.warnings.push record
      return record # so it can also be attached elsewhere
    end

    def tangle_chunks cbn_entry, sink, trace, vsep = 2
      chain_start_loc = nil
      cbn_entry.chunks.each_with_index do |chunk, i|
        vsep.times{sink.newline} unless i.zero?
        if chunk.divert and chunk.initial then
          raise 'assertion failed' if chain_start_loc
          chain_start_loc = sink.location_ahead
        end
        start_location = sink.location_ahead
        chunk.content.each do |node|
          case node.type
          when :verbatim then
            sink.write node.data
          when :newline then
            sink.newline
          when :use then
            tangle_transclusion node, sink, trace, chunk
          else raise 'data structure error'
          end
        end
        end_location = sink.location_behind

        # Both endpoints are inclusive.
        (chunk.tangle_locs ||= []).push OpenStruct.new(
          from: start_location,
          to: end_location)
        if chunk.divert and chunk.final then
          raise 'assertion failed' unless chain_start_loc
          (chunk.divert.chain_tangle_locs ||= []).push \
              OpenStruct.new(
                  from: chain_start_loc,
                  to: sink.location_behind)
          chain_start_loc = nil
        end
      end
      return
    end

    def tangle_transclusion node, sink, trace, referrer
      name = node.name
      if trace.include? name then
        warn node.loc, "circular reference"
        sink.write node.raw
      else
        cbn_entry = @output.chunks_by_name[name]
        if cbn_entry.nil? or cbn_entry.chunks.empty? then
          warn node.loc, "dangling reference"
          sink.write node.raw
        else
          (cbn_entry.transcluders ||= []).push(
              OpenStruct.new(
                name: referrer.name,
                section_number: referrer.section_number,
                ))
          trace.add name
          if node.postprocess then
            # redirect the tangler
            outer_sink = sink
            inner_sport = StringIO.new
            sink = Fabricator::Tangling_Sink.new '(pipe)',
                inner_sport
          end
          sink.pin_indent node.clearindent ? 0 : nil do
            tangle_chunks cbn_entry, sink, trace,
                node.vertical_separation == '.dense' ? 1 : 2
          end
          if node.postprocess then
            # revert the redirect and apply the filter
            sink.newline
            filter_output =
                Fabricator::POSTPROCESSES[node.postprocess].
                call(inner_sport.string)
            sink = outer_sink
            sink.pin_indent node.clearindent ? 0 : nil do
              sink.write_long filter_output
            end
          end
          trace.delete name
        end
      end
      return
    end

    def tangle_roots
      return if @output.tangles
      @output.tangles = {}
      @output.roots.each do |name|
        sport = StringIO.new
        sink = Fabricator::Tangling_Sink.new name, sport
        cbn_entry = @output.chunks_by_name[name]
        # We can assume that [[cbn_entry]] is not [[nil]], for
        # otherwise there wouldn't be a [[roots]] entry.
        tangle_chunks cbn_entry, sink, Set.new([name])
        sink.newline
        @output.tangles[name] = OpenStruct.new(
          filename: name,
          root_type: cbn_entry.root_type,
          content: sport.string,
          line_count: sink.line_count,
          nonblank_line_count: sink.nonblank_line_count,
          longest_line_length: sink.longest_line_length,
        )
      end
      return
    end

    attr_reader :section_count
  end

  class Markup_Parser_Stack < Array
    def initialize suppress_modes = 0
      super()
      push OpenStruct.new(
          content: [],
          mode: Fabricator::MF::DEFAULTS & ~suppress_modes,
          term_type: 0,
        )
      return
    end

    def spawn face, start_flag, end_flag
      self.push OpenStruct.new(
        face: face,
        content: [],
        mode: self.last.mode & ~start_flag | end_flag,
        term_type: end_flag,
      )
      return
    end

    def unspawn
      raise 'assertion failed' unless length >= 2
      top = self.pop
      self.last.content.push OpenStruct.new(
        type: :plain,
        data: top.face,
      ), *top.content
      return
    end

    def ennode node_type, frame_type
      while self.last.term_type != frame_type do
        self.unspawn
      end
      top = self.pop
      node = OpenStruct.new(
          type: node_type,
          content: top.content,
      )
      self.last.content.push node
      return node # for possible further manipulation
    end

    def cancel_link
      i = self.length
      begin
        i -= 1
        self[i].mode &= ~Fabricator::MF::END_LINK
        self[i].mode |= Fabricator::MF::LINK
      end until self[i].term_type == Fabricator::MF::END_LINK
      self[i].term_type = 0
      return
    end
  end

  module MF
    BOLD            = 0x01
    END_BOLD        = 0x02
    ITALIC          = 0x04
    END_ITALIC      = 0x08
    UNDERSCORE      = 0x10
    END_UNDERSCORE  = 0x20
    LINK            = 0x40
    END_LINK        = 0x80

    DEFAULTS = BOLD | ITALIC | UNDERSCORE | LINK
  end

  class Pointered_String < String
    def initialize value
      super value
      @pointer = 0
      return
    end

    attr_accessor :pointer

    def biu_starter? c
      return char_ahead == c &&
          char_ahead(-1) != c &&
          ![?\s, c].include?(char_ahead(1))
    end

    def biu_terminator? c
      return char_ahead == c &&
          char_ahead(1) != c &&
          ![?\s, c].include?(char_ahead(-1))
    end

    def ahead length
      return self[@pointer, length]
    end

    def char_ahead delta = 0
      offset = @pointer + delta
      return offset >= 0 ? self[offset] : nil
    end

    def at? etalon
      return ahead(etalon.length) == etalon
    end
  end

  class Markup_Constructor < Array
    def node type, **attr
      return push(OpenStruct.new(type: type, **attr))
      # [[Array#push]] will return self, allowing [[node]] calls
      # to be chained.
    end

    def plain data
      return node(:plain, data: data)
    end

    def space data = nil
      return node(:space, data: data)
    end

    def words s
      s.split(/(\s+)/, -1).each_with_index do |part, i|
        node(i.even? ? :plain : :space, data: part)
      end
      return self
    end
  end

  POSTPROCESSES = {
    '|scss->css' => proc do |input|
      require 'sass'
      Sass::Engine.new(input,
          syntax: :scss,
          load_paths: [],
          filename: '(pipe)').render
    end,

    '|sass->css' => proc do |input|
      require 'sass'
      Sass::Engine.new(input,
          syntax: :sass,
          load_paths: [],
          filename: '(pipe)').render
    end,

    '|cs->js' => proc do |input|
      require 'coffee-script'
      CoffeeScript.compile input
    end,
  }

  WINDOWS_HOSTED_P =
      (RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/)

  class Tangling_Sink
    def initialize filename, port
      super()
      @filename = filename
      @port = port
      @lineno = 1
      @line = ''
      @indent = 0
      @nonblank_line_count = 0

      @longest_line_length = 0
      return
    end

    def write s
      @line << s
      return
    end

    def newline
      @line.rstrip!
      @port.puts @line
      @lineno += 1
      @nonblank_line_count += 1 unless @line.empty?

      @longest_line_length = @line.length \
          if @line.length > @longest_line_length
      @line = ' ' * @indent
      return
    end

    def pin_indent level = nil
      previous_indent = @indent
      begin
        @indent = level || @line.length
        yield
      ensure
        @indent = previous_indent
      end
      return
    end

    def write_long s
      s.split(/\n/).each_with_index do |line, i|
        newline unless i.zero?
        write line
      end
      return
    end

    def location_ahead
      return OpenStruct.new(
        filename: @filename,
        line: @lineno,
        column: @line.length + 1)
    end

    def location_behind
      return OpenStruct.new(
        filename: @filename,
        line: @lineno,
        column: @line.length)
    end

    def line_count
      return @lineno - 1
    end

    attr_reader :nonblank_line_count

    attr_reader :longest_line_length
  end

  class Text_Wrapper
    def initialize port = $stdout,
        width: 80,
        pseudographics: UNICODE_PSEUDOGRAPHICS,
        palette: DEFAULT_PALETTE
      super()
      @port = port
      @width = width
      @pseudographics = pseudographics
      @palette = palette
      @hangindent = 0
      @curpos = 0
      @curspace = nil
      @curword = OpenStruct.new(
        prepared_output: '',
        width: 0)
      @curmode = @palette.null
      return
    end

    def add_plain data
      if @curspace and @curpos + data.length > @width then
        # the space becomes a linebreak
        @port.puts @palette.null
        @port.print ' ' * @hangindent + @curmode
        @curspace = nil
        @curpos = @hangindent + @curword.width
      end
      @curword.prepared_output << data
      @curpos += data.length
      return
    end

    def add_space data = ' '
      @port.print @curspace.prepared_output if @curspace
      @port.print @curword.prepared_output
      @curspace = OpenStruct.new(
        prepared_output: data,
        width: data.length)
      @curword = OpenStruct.new(
        prepared_output: '',
        width: 0)
      @curpos += data.length
      return
    end

    def linebreak
      @port.print @curspace.prepared_output if @curspace
      @port.print @curword.prepared_output
      @port.puts @palette.null
      @port.print ' ' * @hangindent + @curmode
      @curspace = nil
      @curword = OpenStruct.new(
        prepared_output: '',
        width: 0)
      @curpos = @hangindent
      return
    end

    def add_node node,
        symbolism: Fabricator.default_symbolism
      case node.type
      when :plain then
        add_plain node.data
      when :space then
        add_space node.data || ' '
      when :nbsp then
        add_plain ' '
      when :monospace, :bold, :italic, :underscore then
        styled node.type do
          add_nodes node.content, symbolism: symbolism
        end
      when :mention_chunk then
        add_plain symbolism.chunk_name_delim.begin
        add_nodes Fabricator.parse_markup(node.name,
                Fabricator::MF::LINK),
            symbolism: symbolism
        add_plain symbolism.chunk_name_delim.end
      when :link then
        if node.implicit_face then
          styled :link do
            add_plain '<'
            add_nodes node.content, symbolism: symbolism
            add_plain '>'
          end
        else
          add_plain '<'
          add_nodes node.content, symbolism: symbolism
          unless node.implicit_face then
            add_space ' '
            styled :link do
              add_plain node.target
            end
          end
          add_plain '>'
        end
      else
        # Uh-oh, a bug: the parser generated a node of a type
        # unknown to the weaver.
        raise 'invalid node type'
      end
      return
    end

    def add_nodes nodes,
        symbolism: Fabricator.default_symbolism
      nodes.each do |node|
        add_node node, symbolism: symbolism
      end
      return
    end

    def hang column = nil
      # convert the preceding whitespace, if any, into 'hard'
      # space not subject to future wrapping
      if @curspace then
        @port.print @curspace.prepared_output
        @curspace = nil
      end

      prev_hangindent = @hangindent
      begin
        @hangindent = column || @curpos
        yield
      ensure
        @hangindent = prev_hangindent
      end
      return
    end

    def styled sequence_name
      sequence = @palette[sequence_name]
      raise 'unknown palette entry' unless sequence
      prev_mode = @curmode
      begin
        @curmode = sequence
        @curword.prepared_output << sequence
        yield
      ensure
        @curmode = prev_mode
        @curword.prepared_output << prev_mode
      end
      return
    end

    def add_pseudographics name
      seq = @pseudographics[name]
      raise 'unknown pseudographics item' unless seq
      add_plain seq
      return
    end
  end

  UNICODE_PSEUDOGRAPHICS = OpenStruct.new(
    bullet: [0x2022].pack('U*'),
    initial_chunk_margin: [0x2500, 0x2510].pack('U*'),
    chunk_margin: [0x0020, 0x2502].pack('U*'),
    block_margin: "  ",
    final_chunk_marker:
        ([0x0020, 0x2514] + [0x2500] * 3).pack('U*'),
  )

  ASCII_PSEUDOGRAPHICS = OpenStruct.new(
    bullet: "-",
    initial_chunk_margin: "+ ",
    chunk_margin: "| ",
    block_margin: "  ",
    final_chunk_marker: "----",
  )

  DEFAULT_PALETTE = OpenStruct.new(
    monospace: "\e[38;5;71m",
    bold: "\e[1m",
    italic: "\e[3m",
    underscore: "\e[4m",
    root_type: "\e[4m",
    chunk_frame: "\e[38;5;59m",
    block_frame: "",
    chunk_xref: "\e[38;5;59;3m",
    section_title: "\e[1;48;5;17m",
        # unspecified intense on dark blue background
    rubric: "\e[31;1m",
    section_number: "\e[0;1m",
    chunk_header: "\e[0;33;1m",
    use: "\e[34;1m",
    null: "\e[0m",
    inline_warning: "\e[31m",
    link: "\e[38;5;32m",
  )

  class HTML_Weaving
    def initialize fabric, port,
        title: nil,
        symbolism: Fabricator.default_symbolism,
        link_css: [],
        link_processor: nil
      super()
      @fabric = fabric
      @port = port
      @title = title || "(Untitled)"
      @symbolism = symbolism
      @link_css = link_css
      @link_processor = link_processor
      return()
    end

    def html
      @port.puts '<!doctype html>'
      @port.puts '<html>'
      html_head
      @port.puts '<body>'
      @port.puts
      @port.puts "<h1>#{@title.to_xml}</h1>"
      unless @fabric.warnings.empty? then
        @port.puts "<h2>Warnings</h2>"
        @port.puts
        html_warning_list @fabric.warnings
        @port.puts
      end
      html_presentation
      unless @fabric.index.empty? then
        html_index
      end
      @port.puts '</body>'
      @port.puts '</html>'
      return
    end

    def html_head
      @port.puts '<head>'
      @port.puts "<meta http-equiv='Content-type' " +
          "content='text/html; charset=utf-8' />"
      @port.puts "<title>#{@title.to_xml}</title>"
      if @link_css.empty? then
        @port.puts "<style type='text/css'>"
        @port.write File.read(
            File.join(Fabricator::RESOURCE_DIR, 'maui.css'))
        @port.puts "</style>"
      else
        @link_css.each do |link|
          @port.puts ("<link rel='stylesheet' " +
              "type='text/css' href='%s' />") % link.to_xml
        end
      end
      @port.puts '</head>'
      return
    end

    def html_presentation
      toc_generated = false
      @fabric.presentation.each do |element|
        case element.type
        when :title then
          if !toc_generated then
            html_toc
            toc_generated = true
          end
          @port.print '<h%i' % (element.level + 1)
          @port.print " id='%s'" % "T.#{element.number}"
          @port.print '>'
          @port.print "#{element.number}. "
          htmlify element.content
          @port.puts '</h%i>' % (element.level + 1)
        when :section then
          rubricated = !element.elements.empty? &&
              element.elements[0].type == :rubric
          # If we're encountering the first rubric/title, output
          # the table of contents.
          if rubricated and !toc_generated then
            html_toc
            toc_generated = true
          end

          start_index = 0
          @port.puts "<section class='maui-section' id='%s'>" %
              "S.#{element.section_number}"
          @port.puts
          @port.print "<p>"
          @port.print "<b class='%s'>" %
              (rubricated ? 'maui-rubric' :
                  'maui-section-number')
          @port.print @symbolism.section_prefix
          @port.print element.section_number
          @port.print "."
          if rubricated then
            @port.print " "
            htmlify element.elements[start_index].content
            start_index += 1
          end
          @port.print "</b>"
          subelement = element.elements[start_index]
          warnings = nil
          case subelement && subelement.type
            when :paragraph then
              @port.print " "
              htmlify subelement.content
              start_index += 1
            when :divert then
              @port.print " "
              html_chunk_header subelement, 'maui-divert',
                  tag: 'span'
              warnings = subelement.warnings
              start_index += 1
          end
          @port.puts "</p>"
          if warnings then
            html_warning_list warnings, inline: true
          end
          @port.puts
          element.elements[start_index .. -1].each do |child|
            html_section_part child
            @port.puts
          end
          unless (element.warnings || []).empty? then
            html_warning_list element.warnings, inline: true
            @port.puts
          end
          @port.puts "</section>"
        else raise 'data structure error'
        end
        @port.puts
      end
      return
    end

    def html_section_part element
      case element.type
      when :paragraph then
        @port.print "<p>"
        htmlify element.content
        @port.puts "</p>"

      when :list then
        html_list element.items

      when :divert then
        html_chunk_header element, 'maui-divert'
        @port.puts
        html_warning_list element.warnings, inline: true

      when :chunk, :diverted_chunk then
        @port.print "<div class='maui-chunk"
        @port.print " maui-initial-chunk" if element.initial
        @port.print " maui-final-chunk" if element.final
        @port.print "'>"
        if element.type == :chunk then
          html_chunk_header element, 'maui-chunk-header'
          @port.puts
        end
        html_chunk_body element
        unless (element.warnings || []).empty? then
          html_warning_list element.warnings, inline: true
        end
        if element.final then
          @port.print "<div class='maui-chunk-xref'>"
          htmlify(
              Fabricator.xref_chain(element, @fabric,
                  symbolism: @symbolism,
                  dash: "\u2013",
                  link_sections: true))
          @port.puts "</div>"
        end
        @port.puts "</div>"

      when :block then
        @port.print "<pre class='maui-block'>"
        element.lines.each_with_index do |line, i|
          @port.puts unless i.zero?
          @port.print line.to_xml
        end
        @port.puts "</pre>"
      else
        raise 'data structure error'
      end
      return
    end

    def html_toc
      if @fabric.toc.length >= 2 then
        @port.puts "<h2>Contents</h2>"
        last_level = 0
        # What level should the rubrics in the current
        # (sub(sub))chapter appear at?
        rubric_level = 1
        @fabric.toc.each do |entry|
          if entry.type == :rubric then
            level = rubric_level
          else
            level = entry.level
            rubric_level = entry.level + 1
          end
          if level > last_level then
            raise 'assertion failed' \
                unless level == last_level + 1
            @port.print "\n<ul><li>"
          elsif level == last_level then
            @port.print "</li>\n<li>"
          else
            @port.print "</li></ul>" * (last_level - level) +
                "\n<li>"
          end
          case entry.type
          when :title then
            @port.print "#{entry.number}. "
            @port.print "<a href='#T.#{entry.number}'>"
            htmlify entry.content
            @port.print "</a>"
          when :rubric then
            @port.print @symbolism.section_prefix
            @port.print entry.section_number
            @port.print ". "
            @port.print "<a href='#S.#{entry.section_number}'>"
            htmlify entry.content
            @port.print "</a>"
          else
            raise 'assertion failed'
          end
          last_level = level
        end
        @port.puts "</li></ul>" * last_level; @port.puts
      end
      return
    end

    def html_list items
      @port.puts "<ul>"
      items.each do |item|
        @port.print "<li>"
        htmlify item.content
        if item.sublist then
          @port.puts
          html_list item.sublist.items
        end
        unless (item.warnings || []).empty? then
          @port.puts
          html_warning_list item.warnings, inline: true
        end
        @port.puts "</li>"
      end
      @port.puts "</ul>"
      return
    end

    def html_chunk_header element, cls, tag: 'div'
      @port.print "<#{tag} class='%s'>" % cls.to_xml
      @port.print @symbolism.chunk_name_delim.begin
      if element.root_type then
        @port.print "<u>%s</u> " % element.root_type.to_xml
      end
      htmlify Fabricator.parse_markup(element.name,
          Fabricator::MF::LINK)
      @port.print @symbolism.chunk_name_delim.end + ":"
      @port.print "</#{tag}>"
      # Note that we won't output a trailing linebreak here.
      return
    end

    def html_chunk_body element
      @port.print "<pre class='maui-chunk-body'>"
      element.content.each do |node|
        case node.type
        when :verbatim then
          @port.print node.data.to_xml
        when :newline then
          @port.puts
        when :use then
          @port.print "<span class='maui-transclude'>"
          @port.print @symbolism.chunk_name_delim.begin
          if node.clearindent then
            @port.print ".clearindent "
          end
          htmlify(
              Fabricator.parse_markup(node.name,
                  Fabricator::MF::LINK))
          if node.vertical_separation then
            @port.print " " + node.vertical_separation.to_xml
          end
          if node.postprocess then
            @port.print " " + node.postprocess.to_xml
          end
          @port.print @symbolism.chunk_name_delim.end
          @port.print "</span>"
        else raise 'data structure error'
        end
      end
      @port.puts "</pre>"
      return
    end

    def html_warning_list list, inline: false
      if list and !list.empty? then
        @port.print "<ul class='maui-warnings"
        @port.print " maui-inline-warnings" if inline
        @port.puts "'>"
        list.each do |warning|
          @port.print "<li"
          @port.print " id='W.#{warning.number}'" if inline
          @port.print ">"
          @port.print "!!! " if inline
          if !inline and warning.inline then
            @port.print "<a href='#W.%i'>" % warning.number
          end
          @port.print "<tt>%s</tt>" %
              Fabricator.format_location(warning.loc).to_xml
          @port.print ": " + warning.message
          @port.print "</a>" if !inline and warning.inline
          @port.puts "</li>"
        end
        @port.puts "</ul>"
      end
      return
    end

    def html_index
      @port.puts "<h2>Index</h2>"
      @port.puts
      @port.puts "<nav id='maui-index'>"
      @port.puts "<ul>"
      index = @fabric.index
      index.keys.sort do |a, b|
        index[a].sort_key <=> index[b].sort_key
      end.each do |keyword|
        record = index[keyword]
        @port.print "<li>"
        htmlify record.canonical_representation
        @port.print " "
        record.refs.each_with_index do |(secno, reftype), i|
          @port.print ',' unless i.zero?
          @port.print ' '
          html_index_reference secno, reftype
        end
        @port.puts "</li>"
      end
      @port.puts "</ul>"
      @port.puts "</nav>"
      return
    end

    def html_index_reference secno, reftype
      @port.print "<span class='maui-index-#{reftype}'>"
      case secno
        when Integer then
          @port.print "<a href='#S.#{secno}'>"
          @port.print @symbolism.section_prefix
          @port.print secno
          @port.print "</a>"
        when Range then
          # The hyperlink will reference only the very first
          # section in the range, but we'll mark the whole
          # range up as a link for cosmetic reasons.
          @port.print "<a href='#S.#{secno.begin}'>"
          @port.print @symbolism.section_prefix
          @port.print secno.begin
          @port.print "\u2013"
          @port.print @symbolism.section_prefix
          @port.print secno.end
          @port.print "</a>"
        else
          raise 'assertion failed'
      end
      @port.print "</span>"
      return
    end

    def htmlify nodes
      nodes.each do |node|
        case node.type
        when :plain then
          @port.print node.data.to_xml

        when :space then
          @port.print((node.data || ' ').to_xml)

        when :nbsp then
          @port.print '&nbsp;'

        when :monospace, :bold, :italic, :underscore then
          html_tag = Fabricator::MARKUP2HTML[node.type]
          @port.print "<%s>" % html_tag
          htmlify node.content
          @port.print "</%s>" % html_tag

        when :mention_chunk then
          @port.print "<span class='maui-chunk-mention'>"
          @port.print @symbolism.chunk_name_delim.begin
          htmlify Fabricator.parse_markup(node.name,
              Fabricator::MF::LINK)
          @port.print @symbolism.chunk_name_delim.end
          @port.print "</span>"

        when :link then
          target = node.target
          if @link_processor then
            target, *classes = @link_processor.call target
          else
            classes = []
          end
          @port.print "<a href='#{target.to_xml}'"
          unless classes.empty? then
            @port.print " class='#{classes.join(' ').to_xml}'"
          end
          @port.print ">"
          htmlify node.content
          @port.print "</a>"
        else
          raise 'invalid node type'
        end
      end
      return
    end
  end

  MARKUP2HTML = {
    :monospace => 'code',
    :bold => 'b',
    :italic => 'i',
    :underscore => 'u',
  }
end

class << Fabricator
  def filename_sane? name
    parts = name.split '/', -1
    return false if parts.empty?
    parts.each do |p|
      return false if ['', '.', '..'].include? p
      return false unless p =~ /\A[\w.-]+\Z/
    end
    return true
  end

  def show_warnings fabric
    fabric.warnings.each do |warning|
      $stderr.puts "%s: %s" %
          [format_location(warning.loc), warning.message]
    end
    return
  end

  def format_location h
    if h.column then
      return "%s:%i.%i" % [h.filename, h.line, h.column]
    else
      return "%s:%i" % [h.filename, h.line]
    end
  end

  def format_location_range h, dash: "-"
    if h.from.filename != h.to.filename then
      return format_location(h.from) + dash +
          format_location(h.to)
    else
      if h.from.line != h.to.line then
        result = h.from.filename + ":"
        result << h.from.line.to_s
        result << "." << h.from.column.to_s if h.from.column
        result << dash
        result << h.to.line.to_s
        result << "." << h.to.column.to_s if h.to.column
      else
        result = h.from.filename + ":"
        result << h.from.line.to_s
        if h.from.column or h.to.column then
          result << "." <<
            h.from.column.to_s << dash << h.to.column.to_s
        end
      end
      return result
    end
  end

  def canonicalise raw_name
    name = ''
    raw_name.strip.split(/(\[\[.*?\]*\]\])/, -1).
        each_with_index do |part, i|
      part.gsub! /\s+/, ' ' if i.even?
      name << part
    end
    return name
  end

  def parse_markup s, suppress_modes = 0
    ps = Fabricator::Pointered_String.new s
    stack = Fabricator::Markup_Parser_Stack.new suppress_modes
    while ps.pointer < s.length do
      if ps.at? "[[" and
          end_offset = s.index("]]", ps.pointer + 2) then
        while ps[end_offset + 2] == ?] do
          end_offset += 1
        end
        monospaced_content = []
        ps[ps.pointer + 2 ... end_offset].split(/(\s+)/).
            each_with_index do |part, i|
          monospaced_content.push OpenStruct.new(
              type: i.even? ? :plain : :space,
              data: part
          )
        end
        stack.last.content.push OpenStruct.new(
            type: :monospace,
            content: monospaced_content)
        ps.pointer = end_offset + 2

      elsif stack.last.mode & Fabricator::MF::BOLD != 0 and
          ps.biu_starter? ?* then
        stack.spawn '*',
            Fabricator::MF::BOLD,
            Fabricator::MF::END_BOLD
        ps.pointer += 1

      elsif stack.last.mode & Fabricator::MF::ITALIC != 0 and
          ps.biu_starter? ?/ then
        stack.spawn '/',
            Fabricator::MF::ITALIC,
            Fabricator::MF::END_ITALIC
        ps.pointer += 1

      elsif stack.last.mode & Fabricator::MF::UNDERSCORE \
              != 0 and
          ps.biu_starter? ?_ then
        stack.spawn '_',
            Fabricator::MF::UNDERSCORE,
            Fabricator::MF::END_UNDERSCORE
        ps.pointer += 1

      elsif stack.last.mode & Fabricator::MF::END_BOLD != 0 and
          ps.biu_terminator? ?* then
        stack.ennode :bold, Fabricator::MF::END_BOLD
        ps.pointer += 1

      elsif stack.last.mode & Fabricator::MF::END_ITALIC \
              != 0 and
          ps.biu_terminator? ?/ then
        stack.ennode :italic, Fabricator::MF::END_ITALIC
        ps.pointer += 1

      elsif stack.last.mode & Fabricator::MF::END_UNDERSCORE \
              != 0 and
          ps.biu_terminator? ?_ then
        stack.ennode :underscore, Fabricator::MF::END_UNDERSCORE
        ps.pointer += 1

      elsif stack.last.mode & Fabricator::MF::LINK != 0 and
          ps.biu_starter? ?< then
        stack.spawn '<',
            Fabricator::MF::LINK,
            Fabricator::MF::END_LINK
        stack.last.start_offset = ps.pointer
        ps.pointer += 1

      elsif stack.last.mode & Fabricator::MF::END_LINK != 0 and
          ps.at? '|' and
          end_offset = s.index(?>, ps.pointer + 1) then
        target = ps[ps.pointer + 1 ... end_offset]
        if link_like? target then
          stack.ennode(:link,
              Fabricator::MF::END_LINK).target = target
          ps.pointer = end_offset + 1
        else
          # False alarm: this is not a link, after all.
          stack.cancel_link
          stack.last.content.push OpenStruct.new(
            type: :plain,
            data: '|',
          )
          ps.pointer += 1
        end

      elsif stack.last.mode & Fabricator::MF::END_LINK != 0 and
          ps.at? '>' then
        j = stack.rindex do |x|
          x.term_type == Fabricator::MF::END_LINK
        end
        target = ps[stack[j].start_offset + 1 ... ps.pointer]
        if link_like? target then
          stack[j .. -1] = []
          stack.last.content.push OpenStruct.new(
              type: :link,
              implicit_face: true,
              target: target,
              content: [OpenStruct.new(
                type: :plain,
                data: target,
              )],
          )
        else
          # False alarm: this is not a link, after all.
          stack.cancel_link
          stack.last.content.push OpenStruct.new(
            type: :plain,
            data: '>',
          )
        end
        ps.pointer += 1

      elsif ps.at? ' ' then
        ps.pointer += 1
        while ps.at? ' ' do
          ps.pointer += 1
        end
        stack.last.content.push OpenStruct.new(type: :space)

      elsif ps.at? "\u00A0" then
        stack.last.content.push OpenStruct.new(type: :nbsp)
        ps.pointer += 1

      else
        j = ps.pointer + 1
        while j < s.length and !" */<>[_|".include? ps[j] do
          j += 1
        end
        stack.last.content.push OpenStruct.new(
            type: :plain,
            data: String.new(ps[ps.pointer ... j]),
        )
        ps.pointer = j
      end
    end
    while stack.length > 1 do
      stack.unspawn
    end
    return stack.last.content
  end

  def link_like? s
    return !!(s =~ /\A(?:#\s*)?[[:alnum:]]/)
  end

  def markup
    return Fabricator::Markup_Constructor.new
  end

  # Take a [[results]] record from tangling and construct a
  # matching [[proc]] to be stored in the [[writeout_plan]].
  def plan_to_write_out results
    return proc do |output_filename|
      File.write output_filename, results.content
      puts "Tangled #{results.filename},"
      if results.line_count != 1 then
        print "  #{results.line_count} lines"
      else
        print "  #{results.line_count} line"
      end
      puts " (#{results.nonblank_line_count} non-blank),"
      if results.longest_line_length != 1 then
        puts "  longest #{results.longest_line_length} chars."
      else
        puts "  longest #{results.longest_line_length} char."
      end
      if results.root_type == '.script' and
          !Fabricator::WINDOWS_HOSTED_P then
        stat = File.stat output_filename
        m = stat.mode
        uc = ""
        [(m |= 0o100), (uc << "u")] if m & 0o400 != 0
        [(m |= 0o010), (uc << "g")] if m & 0o040 != 0
        [(m |= 0o001), (uc << "o")] if m & 0o004 != 0
        File.chmod m, output_filename
        puts "Set %s+x on %s, resulting in %03o" % [
          uc,
          output_filename,
          m & 0o777,
        ]
      end
    end
  end

  def load_fabric input, chunk_size_limit: 24
    vp = Fabricator::Vertical_Peeker.new input
    integrator = Fabricator::Integrator.new

    parser_state = OpenStruct.new(
        vertical_separation: nil,
            # the number of blank lines immediately preceding the
            # element currently being parsed
    )
    loop do
      parser_state.vertical_separation = 0
      while vp.peek_line == '' do
        if parser_state.vertical_separation == 2 then
          integrator.warn vp.location_ahead,
              "more than two consecutive blank lines"
        end
        parser_state.vertical_separation += 1
        vp.get_line
      end
      break if vp.eof?
      if parser_state.vertical_separation >= 2 then
        integrator.force_section_break
      end
      element_location = vp.location_ahead
      case vp.peek_line
      when /^\s+/ then
        if !integrator.in_list? or
            vp.peek_line !~ /^
                (?<margin> \s+ )
                - (?<separator> \s+ )
                /x then
          body_location = vp.location_ahead
          element = vp.get_indented_lines_with_skip
          element.type = :block
          element.body_loc = element_location
        else
          margin = $~['margin']
          lines = [$~['separator'] + $']
          vp.get_line
          while !vp.eof? and
              vp.peek_line.start_with? margin and
              vp.peek_line !~ /^\s*-\s/ do
            lines.push vp.get_line[margin.length .. -1]
          end
          element = OpenStruct.new(
            type: :item,
            lines: lines,
            content: parse_markup(lines.map(&:strip).join ' '),
            indent: margin.length,
            loc: element_location)
        end

      when /^<<\s*
          (?: (?<root-type> \.file|\.script)\s+ )?
          (?<raw-name> [^\s].*?)
          \s*>>:$/x then
        name = canonicalise $~['raw-name']
        vp.get_line
        element = OpenStruct.new(
          type: :divert,
          root_type: $~['root-type'],
          name: name,
          header_loc: element_location)

        body_location = vp.location_ahead
        body = vp.get_indented_lines_with_skip
        if body then
          element.type = :chunk
          element.lines = body.lines
          element.indent = body.indent
          element.body_loc = body_location
          element.initial = element.final = true
        end

      when /^-\s/ then
        # We'll discard the leading dash but save the following
        # whitespace.
        lines = [vp.get_line[1 .. -1]]
        while !vp.eof? and
            vp.peek_line != '' and
            vp.peek_line !~ /^\s*-\s/ do
          lines.push vp.get_line
        end
        element = OpenStruct.new(
          type: :item,
          lines: lines,
          content: parse_markup(lines.map(&:strip).join ' '),
          indent: 0,
          loc: element_location)

      when /^\.\s+/ then
        name = $'
        element = OpenStruct.new(
            type: :index_anchor,
            name: name)
        vp.get_line

      when /^[^\s]/ then
        lines = []
        while vp.peek_line =~ /^[^\s]/ and
            vp.peek_line !~ /^-\s/ do
          lines.push vp.get_line
        end
        mode_flags_to_suppress = 0
        case lines[0]
        when /^(==+)(\s+)/ then
          lines[0] = $2 + $'
          element = OpenStruct.new(
            type: :title,
            level: $1.length - 1,
            loc: element_location)
          mode_flags_to_suppress |= Fabricator::MF::LINK

        when /^\*\s+/ then
          lines[0] = $'
          element = OpenStruct.new(
              type: :rubric,
              loc: element_location)

        else
          element = OpenStruct.new(
              type: :paragraph,
              loc: element_location)
        end
        element.lines = lines
        element.content =
            parse_markup(lines.map(&:strip).join(' '),
            mode_flags_to_suppress)
      else raise 'assertion failed'
      end
      integrator.integrate element
    end
    integrator.force_section_break
    integrator.clear_diversion
    integrator.check_chunk_sizes(chunk_size_limit)
    integrator.tangle_roots
    return integrator.output
  end

  def weave_ctxt fabric, port,
      width: 80,
      symbolism: default_symbolism,
      pseudographics: Fabricator::UNICODE_PSEUDOGRAPHICS
    wr = Fabricator::Text_Wrapper.new port,
        width: width,
        pseudographics: pseudographics
    unless fabric.warnings.empty? then
      wr.styled :section_title do
        wr.add_plain 'Warnings'
      end
      wr.linebreak
      wr.linebreak
      weave_ctxt_warning_list fabric.warnings, wr
      wr.linebreak
    end
    toc_generated = false
    fabric.presentation.each do |element|
      case element.type
      when :title then
        if !toc_generated then
          weave_ctxt_toc fabric.toc, wr,
              symbolism: symbolism
          toc_generated = true
        end
        wr.styled :section_title do
          wr.add_plain "#{element.number}."
          wr.add_space
          wr.hang do
            wr.add_nodes element.content, symbolism: symbolism
          end
        end
        wr.linebreak
        wr.linebreak
      when :section then
        # [[element.elements]] can be empty if a section contains
        # index anchor(s) but no content.  This is a pathological
        # case, to be sure, but it can happen, so we'll need to check.
        rubricated = !element.elements.empty? &&
            element.elements[0].type == :rubric
        # If we're encountering the first rubric/title, output
        # the table of contents.
        if rubricated and !toc_generated then
          weave_ctxt_toc fabric.toc, wr,
              symbolism: symbolism
          toc_generated = true
        end

        start_index = 0 # index of the first non-special child
        if rubricated then
          start_index += 1
          wr.styled :rubric do
            wr.add_plain "%s%i." % [
              symbolism.section_prefix,
              element.section_number]
            wr.add_space
            wr.add_nodes element.elements.first.content,
                symbolism: symbolism
          end
        else
          wr.styled :section_number do
            wr.add_plain "%s%i." % [
              symbolism.section_prefix,
              element.section_number]
          end
        end

        # If the rubric or the section sign is followed by a
        # paragraph, a chunk header, or a divert, we'll output
        # it in the same paragraph.
        starter = element.elements[start_index]
        if starter then
          case starter.type
          when :paragraph, :divert, :chunk then
            wr.add_space
            weave_ctxt_section_part starter, fabric, wr,
                symbolism: symbolism
            start_index += 1
          else
            wr.linebreak
          end
        end

        # Finally, the blank line that separates the special
        # paragraph from the section's body, if any.
        wr.linebreak

        element.elements[start_index .. -1].each do |child|
          weave_ctxt_section_part child, fabric, wr,
              symbolism: symbolism
          wr.linebreak
        end

        unless (element.warnings || []).empty? then
          weave_ctxt_warning_list element.warnings, wr,
              inline: true, indent: false
          wr.linebreak
        end
      else raise 'data structure error'
      end
    end
    unless fabric.index.empty? then
      wr.styled :section_title do
        wr.add_plain 'Index'
      end
      wr.linebreak; wr.linebreak
      index = fabric.index
      index.keys.sort do |a, b|
        index[a].sort_key <=> index[b].sort_key
      end.each do |keyword|
        record = index[keyword]
        wr.add_nodes record.canonical_representation
        wr.hang 2 do
          record.refs.each_with_index do |(secno, reftype), i|
            wr.add_plain ',' unless i.zero?
            wr.add_space
            formatted_reference = _format_ctxt_index_ref secno,
                symbolism: symbolism
            case reftype
            when :manual then
              wr.add_plain formatted_reference

            when :definition then
              wr.styled :underscore do
                wr.add_plain formatted_reference
              end

            when :transclusion then
              wr.styled :italic do
                wr.add_plain formatted_reference
              end

            else
              raise 'assertion failed'
            end
          end
        end
        wr.linebreak
      end
    end
    return
  end

  def weave_ctxt_warning_list list, wr, inline: false,
      indent: true
    list.to_a.each do |warning|
      wr.styled inline ? :inline_warning : :null do
        wr.add_plain (indent ? '  ' : '') + '!!! ' if inline
        wr.add_plain format_location(warning.loc)
        wr.add_plain ':'
        wr.add_space
        wr.hang do
          warning.message.split(/(\s+)/).
              each_with_index do |part, i|
            if i.even? then
              wr.add_plain part
            else
              wr.add_space part
            end
          end
        end
      end
      wr.linebreak
    end
    return
  end

  def weave_ctxt_section_part element, fabric, wr,
      symbolism: default_symbolism
    case element.type
    when :paragraph then
      wr.add_nodes element.content, symbolism: symbolism
      wr.linebreak

    when :divert, :chunk, :diverted_chunk then
      if [:divert, :chunk].include? element.type then
        weave_ctxt_chunk_header element, wr,
            symbolism: symbolism
        weave_ctxt_warning_list element.warnings, wr,
            inline: true
      end
      if [:chunk, :diverted_chunk].include? element.type then
        wr.styled :chunk_frame do
          wr.add_pseudographics element.initial ?
            :initial_chunk_margin :
            :chunk_margin
        end
        wr.styled :monospace do
          element.content.each do |node|
            case node.type
            when :verbatim then
              wr.add_plain node.data
            when :newline then
              wr.linebreak
              wr.styled :chunk_frame do
                wr.add_pseudographics :chunk_margin
              end
            when :use then
              weave_ctxt_use node, wr,
                  symbolism: symbolism
            else raise 'data structure error'
            end
          end
        end
        wr.linebreak
        if element.final then
          wr.styled :chunk_frame do
            wr.add_pseudographics :final_chunk_marker
          end
          wr.linebreak
        end
        weave_ctxt_warning_list element.warnings, wr,
            inline: true
        if element.final then
          wr.styled :chunk_xref do
            wr.add_nodes xref_chain(element, fabric,
                    symbolism: symbolism),
                symbolism: symbolism
          end
          wr.linebreak
        end
      end

    when :list then
      _weave_ctxt_list element.items, wr,
          symbolism: symbolism

    when :block then
      weave_ctxt_block element, wr
    else
      raise 'data structure error'
    end
    return
  end

  def weave_ctxt_chunk_header element, wr,
      symbolism: default_symbolism
    wr.styled :chunk_header do
      wr.add_plain symbolism.chunk_name_delim.begin
      if element.root_type then
        wr.styled :root_type do
          wr.add_plain element.root_type
        end
        wr.add_space
      end
      wr.add_nodes Fabricator.parse_markup(element.name,
              Fabricator::MF::LINK),
          symbolism: symbolism
      wr.add_plain symbolism.chunk_name_delim.end
      wr.add_plain ":"
    end
    wr.linebreak
    return
  end

  def weave_ctxt_block element, wr
    element.lines.each do |line|
      wr.styled :block_frame do
        wr.add_pseudographics :block_margin
      end
      wr.styled :monospace do
        wr.add_plain line
      end
      wr.linebreak
    end
    return
  end

  def weave_ctxt_use node, wr,
      symbolism: default_symbolism
    wr.styled :use do
      wr.add_plain symbolism.chunk_name_delim.begin
      if node.clearindent then
        wr.add_plain ".clearindent "
      end
      wr.add_nodes Fabricator.parse_markup(node.name,
              Fabricator::MF::LINK),
          symbolism: symbolism
      if node.vertical_separation then
        wr.add_plain " " + node.vertical_separation
      end
      if node.postprocess then
        wr.add_plain " " + node.postprocess
      end
      wr.add_plain symbolism.chunk_name_delim.end
    end
    return
  end

  # Given a chunk, prepare its transclusion summary as a list of
  # markup nodes.  Should only be used on chunks that are the
  # last in a chunk chain (i.e., that have [[final]] set).
  def xref_chain element, fabric,
      dash: "-", # used to indicate ranges
      symbolism: default_symbolism,
      link_sections: false
    xref = markup
    if element.initial then
      xref.words "This chunk is "
    else
      xref.words "These chunks are "
    end
    cbn_entry = fabric.chunks_by_name[element.name]
    transcluders = cbn_entry.transcluders
    if transcluders then
      xref.words "transcluded by "
      xref.push *commatise_oxfordly(
          transcluders.map{|ref| markup.
              node(:mention_chunk, name: ref.name).
              space.
              plain("(").
              node(:link,
                content: markup.
                    plain(symbolism.section_prefix +
                        ref.section_number.to_s),
                target: "#S.#{ref.section_number}").
              plain(")")
          })
    else
      if cbn_entry.root_type then
        xref.words "solely a transclusion root"
      else
        xref.words "never transcluded"
      end
    end
    xref.words " and "
    tlocs = element.divert ?
        element.divert.chain_tangle_locs :
        element.tangle_locs
    if tlocs then
      xref.
          words("tangled to ").
          push(*commatise_oxfordly(
          tlocs.map{|range| markup.
              plain(format_location_range(range, dash: dash))
          })).
          plain(".")
    else
      xref.words "never tangled."
    end
    return xref
  end

  def commatise_oxfordly items
    result = []
    items.each_with_index do |item, i|
      unless i.zero? then
        unless items.length == 2 then
          result.push OpenStruct.new(:type => :plain,
              :data => ',')
        end
        result.push OpenStruct.new(:type => :space)
        if i == items.length - 1 then
          result.push OpenStruct.new(:type => :plain,
              :data => 'and')
          result.push OpenStruct.new(:type => :space)
        end
      end
      result.push *item
    end
    return result
  end

  def _weave_ctxt_list items, wr,
      symbolism: default_symbolism
    items.each do |item|
      wr.add_pseudographics :bullet
      wr.add_plain " "
      wr.hang do
        wr.add_nodes item.content, symbolism: symbolism
      end
      wr.linebreak
      unless (item.warnings || []).empty? then
        wr.hang do
          weave_ctxt_warning_list item.warnings, wr,
              inline: true
        end
      end
      if item.sublist then
        wr.add_plain "  "
        wr.hang do
          _weave_ctxt_list item.sublist.items, wr,
              symbolism: symbolism
        end
      end
    end
    return
  end

  def weave_ctxt_toc toc, wr,
      symbolism: default_symbolism
    if toc.length >= 2 then
      wr.styled :section_title do
        wr.add_plain 'Contents'
      end
      wr.linebreak; wr.linebreak
      rubric_level = 0
      toc.each do |entry|
        case entry.type
        when :title then
          rubric_level = entry.level - 1 + 1
          wr.add_plain '  ' * (entry.level - 1)
          wr.add_plain entry.number + '.'
          wr.add_space
          wr.hang do
            wr.add_nodes entry.content, symbolism: symbolism
          end

        when :rubric then
          wr.add_plain '  ' * rubric_level
          wr.add_plain '%s%i.' % [
            symbolism.section_prefix,
            entry.section_number]
          wr.add_space
          wr.hang do
            wr.add_nodes entry.content, symbolism: symbolism
          end

        else
          raise 'assertion failed'
        end
        wr.linebreak
      end
      wr.linebreak
    end
    return
  end

  def _format_ctxt_index_ref target,
      symbolism: Fabricator.default_symbolism
    return case target
      when Integer then
        symbolism.section_prefix + target.to_s
      when Range then
        symbolism.section_prefix + target.begin.to_s +
            "-" +
            symbolism.section_prefix + target.end.to_s
      else
        raise 'type mismatch'
    end
  end

  def weave_html fabric, port,
      title: nil,
      symbolism: default_symbolism,
      link_css: [],
      link_processor: nil
    weaving = Fabricator::HTML_Weaving.new fabric, port,
        title: title,
        symbolism: symbolism,
        link_css: link_css,
        link_processor: link_processor
    weaving.html
    return
  end

  def default_symbolism
    return OpenStruct.new(
        section_prefix: "§",
        # Two endpoints are stored in a [[Range]].
        chunk_name_delim: "\u00AB" .. "\u00BB")
  end
end
