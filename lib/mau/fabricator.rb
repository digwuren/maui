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
        # is the /following/ line's indentation.
        indent = $&.length if indent.nil? or $&.length < indent
        lines.push get_line
      end
      return nil if lines.empty?
      lines.each{|l| l[0 ... indent] = ''}
      return OpenStruct.new(lines: lines, indent: indent)
    end

    def parse_block prefix
      lines = []
      while !eof? and peek_line[0] == prefix do
        lines.push get_line[1 .. -1]
      end

      indent = nil
      lines.each do |line|
        next if line.empty?
        line =~ /^\s*/
        if indent then
          indent = [indent, $&.length].min
        else
          indent = $&.length
        end
      end
      if indent and indent != 0 then
        lines = lines.map{|l| l[indent .. -1]}
      end

      return lines * "\n"
    end

    def initialize port,
        filename: nil,
        first_line: 1
      super()
      @port = port
      @filename =
          if filename then
            filename
          elsif @port.respond_to? :path then
            @filename = @port.path
          elsif @port == $stdin then
            @filename = '(stdin)'
          else
            @filename = '(unknown)'
          end
      @buffer = []
      @line_number = first_line
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
            #   root_type: String
            #   chunks: list of OL_CHUNK/OL_DIVERTED_CHUNK nodes
            #   headers: list of OL_CHUNK/OL_DIVERT records

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
      # We'll issue all chunks 'ord' numbers in the order they
      # appear, so that we can use these as a fall-back sort key
      # when sorting chunks by optional sequence numbers.
      # (Recall that Ruby's [[sort]] is not stable.)
      # Intuitively, we could just use section numbers, but this
      # fails when we'll preload a 'base' fabric before the main
      # fabric without assigning the base fabric any section
      # numbers.
      @chunk_ord_counter = 0
      @title_counters = [0]
      @curdivert = nil # The current diversion if active
      @last_divertee = nil
          # last chunk diverted by [[@curdivert]]
      @list_stack = nil
      @in_code = false
      @last_title_level = 0
      @warning_counter = 0
      @nesting_stack = []
      @blockquote = nil
      @subplot = nil
      @toc_candidate = nil
      return
    end

    def integrate element,
        suppress_indexing: false,
        suppress_narrative: false
      if !suppress_narrative and
          [OL_TITLE, OL_SUBPLOT, OL_SECTION].include?(
              element.type) and
          @subplot.nil? and
          (@toc_candidate.nil? or
              @toc_candidate.type == OL_NOP) then
        @toc_candidate = OpenStruct.new type: OL_NOP
        @output.presentation.push @toc_candidate
      end
      if element.type == OL_TITLE then
        force_section_break
        # Enforce (sub(sub))chapter-locality of diversions
        clear_diversion

        # Check the title's level restriction
        if element.level > @last_title_level + 1 then
          warn element.loc, "title level too deep"
          element.level = @last_title_level + 1
        end
        @last_title_level = element.level

        unless suppress_narrative then
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
          @output.presentation.push element
          @output.toc.push element

          # If this is the first TOC entry, promote our TOC candidate
          # into the actual place for implicit TOC
          if @toc_candidate.type == OL_NOP then
            @toc_candidate.type = OL_IMPLICIT_TOC
          end
        end
      elsif element.type == OL_SUBPLOT then
        force_section_break
        # [[force_section_break]] clears [[@in_code]]
        raise 'assertion failed' \
            if @in_code
        # [[subplots can not appear in blockquotes]]
        raise 'assertion failed' \
            if @blockquote

        if @subplot.nil? then
          @output.presentation.push element
        else
          @subplot.elements.push element
        end

        @nesting_stack.push @subplot, @curdivert
        @curdivert = nil
        @blockquote = nil
        @subplot = element
      elsif element.type == OL_THEMBREAK then
        unless @blockquote then
          force_section_break
          # but won't clear diversion
          unless suppress_narrative then
            @output.presentation.push element
          end
        else
          @blockquote.elements.push element
        end
      elsif element.type == OL_EXPLICIT_TOC then
        clear_diversion
        force_section_break
        unless suppress_narrative then
          raise 'assertion failed' unless @subplot.nil?
          @output.presentation.push element
          if @toc_candidate and
              @toc_candidate.type == OL_IMPLICIT_TOC then
            # cancel the previous automatic TOC placement
            @toc_candidate.type = OL_NOP
          end
          @toc_candidate = element
        end
        while @title_counters.length > 1 do
          @title_counters.pop
        end
        @last_title_level = 0
      else
        if element.type == OL_BLOCK and @curdivert then
          element.type = OL_DIVERTED_CHUNK
          element.name = @curdivert.name
          element.seq = @curdivert.seq
          element.divert = @curdivert

          element.initial = true if @last_divertee.nil?
          @last_divertee = element
        end
        if element.type & OLF_HAS_HEADER != 0 then
          clear_diversion
        end
        if (@cursec and
                element.type == OL_RUBRIC) or
            (@in_code and
                element.type & OLF_NARRATIVE != 0) then
          (@cursec.warnings ||= []).push \
              warn(element.loc,
                  "silent section break",
                  inline: true)
          force_section_break
        end
        if @cursec.nil? then
          @cursec = OpenStruct.new(
            type: OL_SECTION,
            section_number: nil,
            elements: [],
            loc: element.loc)
          unless suppress_narrative then
            @cursec.section_number =
                @first_section_number + @section_count
            @section_count += 1
            if @subplot.nil? then
              @output.presentation.push @cursec
            else
              @subplot.elements.push @cursec
            end
          end
        end
        if !suppress_narrative and element.type == OL_RUBRIC then
          element.section_number = @cursec.section_number
          @output.toc.push element
          # If this is the first TOC entry, promote our TOC candidate
          # into the actual place for implicit TOC
          if @toc_candidate.type == OL_NOP then
            @toc_candidate.type = OL_IMPLICIT_TOC
          end
        end
        if element.type == OL_DIVERT then
          @curdivert = element
          raise 'assertion failed' unless @last_divertee.nil?
        end

        if element.type == OL_ITEM then
          # Is this a top-level or descendant item?
          unless @list_stack then
            raise 'assertion failed' unless element.indent == 0

            # Create a new [[OL_LIST]] node.
            new_list = OpenStruct.new(
              type: OL_LIST,
              items: [],
              indent: element.indent)
            unless @blockquote then
              @cursec.elements.push new_list
            else
              @blockquote.elements.push new_list
            end
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
                type: OL_LIST,
                items: [],
                indent: element.indent)
              @list_stack.last.items.last.sublist = new_list
              @list_stack.push new_list
            end
          end

          # The list structure has been prepared.  Append the
          # new element to the innermost list in progress.
          @list_stack.last.items.push element
        elsif element.type == OL_INDEX_ANCHOR then
          unless suppress_indexing then
            freeform_index_record(element.name).refs.push [
                @cursec.section_number, :manual]
          end
        else
          @list_stack = nil
          unless @blockquote then
            @cursec.elements.push element
          else
            @blockquote.elements.push element
          end
          if element.type & OLF_FUNCTIONAL != 0 then
            element.section_number = @cursec.section_number \
                unless suppress_narrative

            cbn_record =
                @output.chunks_by_name[element.name] ||=
                    OpenStruct.new(chunks: [], headers: [])

            if element.type & OLF_HAS_HEADER != 0 then
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

            unless suppress_indexing then
              case element.type
                when OL_CHUNK then
                  chunk_index_record(element.name).refs.push [
                      @cursec.section_number, :definition]

                when OL_DIVERT then
                  index_ref = [@cursec.section_number ..
                      @cursec.section_number, :definition]
                  chunk_index_record(element.name).refs.push(
                      index_ref)
                  # We'll add a pointer to this reference entry
                  # into [[@curdivert]] so we can replace the
                  # range later to cover all the sections in
                  # which headerless chunks collected by this
                  # divert are present.
                  @curdivert.index_ref = index_ref

                when OL_DIVERTED_CHUNK then
                  prev_range = @curdivert.index_ref[0]
                  @curdivert.index_ref[0] = prev_range.begin ..
                      @cursec.section_number
                else raise 'assertion failed'
              end
            end

            if element.type & OLF_HAS_CODE != 0 then
              cbn_record.chunks.push element
              element.ord = (@chunk_ord_counter += 1)
              parse_chunk_content element
              unless suppress_indexing then
                element.content.each do |node|
                  next unless node.type == :use
                  chunk_index_record(node.name).refs.push [
                      @cursec.section_number, :transclusion]
                end
              end
            end
          end
          if element.type == OL_BLOCKQUOTE then
            # [[@in_code]] should be clear at this point --
            # [[OL_BLOCKQUOTE]] is a narrative node type, so even if it
            # was set before, the preparatory code should have performed
            # an automatic section break, which should have cleared
            # [[@in_code]].  Thus, we can restore it to [[false]]
            # without having to save it in the [[@nesting_stack]] frame.
            raise 'assertion failed' \
                if @in_code

            # We won't need to save or restore [[@subplot]] or
            # [[@curdivert]], for these are not supposed to change
            # during the parsing of a blockquote.  We'll just save
            # [[@blockquote]] (which may be [[nil]]).
            @nesting_stack.push @blockquote
            @blockquote = element
          end

          # If a chunk body is followed by a narrative-type
          # element, we'll want to generate an automatic section
          # break.  To that end, we'll set the [[@in_code]] flag
          # when we encounter a node with a chunk body.
          if element.type & OLF_HAS_CODE != 0 then
            @in_code = true
          end
        end
      end
      return
    end

    def end_subplot
      force_section_break
      @blockquote = nil
      @curdivert = @nesting_stack.pop
      raise 'assertion failed' \
          unless @curdivert.nil? or @curdivert.type == OL_DIVERT
      @subplot = @nesting_stack.pop
      raise 'assertion failed' \
          unless @subplot.nil? or @subplot.type == OL_SUBPLOT
      # the [[force_section_break]] above should have ensured that
      # [[@in_code]] is cleared
      raise 'assertion failed' \
          if @in_code
      return
    end

    def end_blockquote
      @blockquote = @nesting_stack.pop
      raise 'assertion failed' \
          unless @blockquote.nil? or
              @blockquote.type == OL_BLOCKQUOTE
      @in_code = false
      return
    end

    def parse_chunk_content element
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
                    # for ordering of the [[OpenStruct]]
                    # fields; will be set below
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
      return
    end

    def chunk_index_record name
      identifier = "<< " +
          Fabricator.canonicalise(name) +
          " >>"
      markup = [OpenStruct.new(
          type: MU_MENTION_CHUNK,
          name: name)]
      return _index_record identifier, markup
    end

    def freeform_index_record name
      identifier = Fabricator.canonicalise(name)
      markup = Fabricator.parse_markup name, PF_LINK
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
        # Section nodes are only created when there's at least
        # one element to be integrated.  This element may be an
        # index anchor, which is not actually added into the
        # section's [[elements]] list.  Since this is the only
        # such case, the meaning of [[elements]] being empty by
        # the end of the section is unambiguous.
        (@cursec.warnings ||= []).push \
            warn(@cursec.loc,
                "section with index anchor(s) but no content",
                inline: true)
      end
      @cursec = nil
      @list_stack = nil
      @blockquote = nil
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
        next unless node.type == OL_SECTION
        node.elements.each do |element|
          next unless (element.type & OLF_HAS_CODE) != 0
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
      raise 'assertion failed' \
          if location.nil?
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
      chunks = cbn_entry.chunks.sort_by do |c|
        [c.seq || 1000, c.ord]
      end

      chunks.each_with_index do |chunk, i|
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

  OLF_HAS_HEADER     = 0x01
  OLF_HAS_CODE       = 0x02
  OLF_FUNCTIONAL     = OLF_HAS_HEADER | OLF_HAS_CODE

  OLF_NARRATIVE      = 0x08

  OL_NOP             = 0x00
  OL_TITLE           = 0x10
  OL_SECTION         = 0x20
  OL_RUBRIC          = 0x30 | OLF_NARRATIVE
  OL_ITEM            = 0x40 | OLF_NARRATIVE
  OL_LIST            = 0x50 | OLF_NARRATIVE
  OL_PARAGRAPH       = 0x60 | OLF_NARRATIVE
  OL_BLOCK           = 0x70 | OLF_NARRATIVE
  OL_DIVERT          = 0x80 | OLF_HAS_HEADER
  OL_DIVERTED_CHUNK  = 0x80 | OLF_HAS_CODE
  OL_CHUNK           = 0x80 | OLF_HAS_HEADER | OLF_HAS_CODE
  OL_INDEX_ANCHOR    = 0x90
  OL_THEMBREAK       = 0xA0 | OLF_NARRATIVE
  OL_BLOCKQUOTE      = 0xB0 | OLF_NARRATIVE
  OL_SUBPLOT         = 0xC0
  OL_IMPLICIT_TOC    = 0xD0
  OL_EXPLICIT_TOC    = 0xE0

  MU_PLAIN           = 0x00
  MU_SPACE           = 0x01
  MU_BOLD            = 0x03
  MU_ITALIC          = 0x04
  MU_UNDERSCORE      = 0x05
  MU_MONOSPACE       = 0x06
  MU_LINK            = 0x07
  MU_MENTION_CHUNK   = 0x08
  MU_SPECIAL_ATOM    = 0x09

  SA_NBSP      = 0x01
  SA_NDASH     = 0x02
  SA_MDASH     = 0x03
  SA_ELLIPSIS  = 0x04

  class Markup_Parser_Stack < Array
    def initialize suppress_modes = 0
      super()
      push OpenStruct.new(
          content: Fabricator.markup,
          mode: PF_DEFAULTS & ~suppress_modes,
          term_type: 0,
        )
      return
    end

    def spawn face, start_flag, end_flag
      self.push OpenStruct.new(
        face: face,
        content: Fabricator.markup,
        mode: self.last.mode & ~start_flag | end_flag,
        term_type: end_flag,
      )
      return
    end

    def unspawn
      raise 'assertion failed' unless length >= 2
      top = self.pop
      self.last.content.
          plain(top.face).
          concat(top.content)
      return
    end

    def ennode node_type, frame_type, **attr
      while self.last.term_type != frame_type do
        self.unspawn
      end
      top = self.pop
      self.last.content.node node_type,
          content: top.content,
          **attr
      return
    end

    def cancel_link
      i = self.length
      begin
        i -= 1
        self[i].mode &= ~PF_END_LINK
        self[i].mode |= PF_LINK
      end until self[i].term_type == PF_END_LINK
      self[i].term_type = 0
      return
    end
  end

  PF_BOLD            = 0x01
  PF_END_BOLD        = 0x02
  PF_ITALIC          = 0x04
  PF_END_ITALIC      = 0x08
  PF_UNDERSCORE      = 0x10
  PF_END_UNDERSCORE  = 0x20
  PF_LINK            = 0x40
  PF_END_LINK        = 0x80

  PF_DEFAULTS = PF_BOLD | PF_ITALIC | PF_UNDERSCORE |
      PF_LINK

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

    def char_ahead delta = 0
      offset = @pointer + delta
      return offset >= 0 ? self[offset] : nil
    end

    def at? etalon
      return self[@pointer, etalon.length] == etalon &&
          !unicode_combining?(self[@pointer + etalon.length] || 0)
    end

    def unicode_combining? cp
      # Special case: a single block with large codes
      return true if (0xE0100 .. 0xE01EF).include? cp

      # Check the range
      return false unless (0x0300 .. 0x1E8D6).include? cp

      # Discard eight lower bits; perform the first look-up;
      # multiply the result with the size of a single bitfield
      ptr = UNICODE_COMBININGS.getbyte(cp >> 8) << 5
      # Advance the pointer to byte granularity
      ptr += (cp >> 3) & 0x1F
      # Perform the second lookup and convert the bit into a
      # Boolean value
      return UNICODE_COMBININGS.getbyte(ptr + 489)[cp & 7] != 0
    end

    # 2217 bytes of index and bitfields
    UNICODE_COMBININGS = (
      "AAAACAsYKC40ISIaIxwbFw4AAAcAAAAeEAUVLDEzAAApAAAAAAAAAAAA" +
      "AAArNQAADQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACoA" +
      "LSQwJwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB" +
      "AAADAAAyIAoAAAAAAAAlAAAAAAAUGSYJFh8TAgAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAvBAAAAAwAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADwAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAEQYAAAAAAAAAEgAAAAAAAAAAAAAAAAAdAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAOC8DwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA//8A" +
      "AP//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAB/AAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAACHAQQOAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAOAAAAAAAAAAAAAAAAAAAAAAAAAAAP//////////////" +
      "////AAAAAAAAAAAAAAAAAAAAAAAAAwAAAAAAABABAAAAwB8fAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAMAHAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAD4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAACABwAAAAAAAAAAAAAAAAAAAAAAADwAAAAAAAAAAAAAAAAA" +
      "BgAAAAAAAAAAAAAAAAAAAAAA4P1mAAAAwwEAHgBkIAAgAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAGAAAAAAAAAAAAAAAAAAOAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIADAPjn" +
      "DwAAADwAAAAAAAAAAAAA////////f/j//////x8gABAAAPj+/wAAAAAA" +
      "AAAAAAAAAAAAAAD4pwEAAAAAAAAAAAAAAAAovwAAAAAAAAAAAAIAAAAA" +
      "AAD/fwAAAAAAAIADAAAAAAB4BgAAAAAAAAAAAACACQAAAAAAAEB/5R/4" +
      "nwAAAAAAAP8/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA+IUN" +
      "AAAAAAAAAAAAAAMAAKACAAAAAAAA/n/f4P/+////H0AAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAA/v////+/tgAAAAAAAAAHAAAAgO8fAAAAAAAA" +
      "AAgAAwAAAAAAwH8AHAAAAAAAAAIAAAAAAACQHiBAAAwAAAAEAAAAAAAA" +
      "AAEgAAAAAAAAAAAAAAAA8geAfwAAAAAAAAAAAAAAAPIbAD8AAAAAAAAC" +
      "AAAAAAAAAB4gAAAMAAAAAAAAAAAAAAAABFwAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAfwAAAAAAAAAcAAAAHAAAAAwAAAAMAAAAAAAA" +
      "ALA/QP4PIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPLABAAAwAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABAAAABwAAAAAAABT+" +
      "If4ADAAAAAIAAAAAAAAQHiAAAAwAAAAGAAAAAAAAEIY5AgAAACMABgAA" +
      "AAAAABC+IQAADAAAAAEAAAAAAADAwT1gAAwAAAACAAAAAAAAkEAwAAAM" +
      "AAAAAAAAAMA/AACA/wMAAAAAAAcAAAAAAMgTAAAAACAAAABu8AAAAAAA" +
      "hwAAAAAAAAAAAAAAAAAAAAAAAAAAYAAAAAAAAAAAgNMAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAID4BwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "ACAhAAAAAP8HAAAAAAD4//8AAAEAAAAAAAAAAAAAAMCfnz0AAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAA/x/i/wEAAAAAAAAAAAAAAAAAAIDw" +
      "PwAAAMAAAAAAAAAAAAAAAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAIADAA8AAAAAANAXBAAAAAD4DwADAAAAPDsAAAAAAABAowMARAgA" +
      "AGAAAAAAAAAAAAAAAAAAAAAAAAAAEAAAAP//AwAAAAIAAAD///8HAAAA" +
      "AAAAAAAAAMD/AQAAAAAAAPgPAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAB8AAAAAAAB+ZgAIEAAAAAAAEAAAAAAAAJ3BAgAAAAAwQAAA" +
      "AAAAAPDPAAAAAAAAAAAAAAAAAAAAAAAAAPf//SEQAwAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAA////////P/AAAMD77z4AAAAAAA4AAAAAAAAAAAAAAAAAAAAA+P//" +
      "/wAAAAAAAAAAAAAAAAAAAIAAAAAAAAAAAAAAAAD/////"
    ).unpack('m').first

    def unicode_alphanumeric? cp
      return false unless (0x0030 .. 0x2FA1D).include? cp
      ptr = UNICODE_ALPHANUMERICS.getbyte(cp >> 8) << 5
      ptr += (cp >> 3) & 0x1F
      return UNICODE_ALPHANUMERICS.getbyte(ptr + 763)[cp & 7] != 0
    end

    # 3995 bytes of index and bitfields
    UNICODE_ALPHANUMERICS = (
      "VGQuVl4zTkEbPDs0MjArEFBkWUpjZDlANycYLDgfZEYVDgAAWAAAEgAA" +
      "AABIKgUAUVceAGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGQcZGRkZGRk" +
      "ZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRk" +
      "ZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkI2RkZGRLZDFV" +
      "SUw1PmRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRk" +
      "ZGRkZGRFAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZCZa" +
      "ZENHKUIPRCIZCmQLUlsvGlMADQA/Nj0JJSggBk0AOgAAAAAAZGRkFF8H" +
      "AAAAAAAAAAAAAGRkZGQEAAAAAAAAAAAAAAAAAAAAZGQIAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZGQtEQAAABYAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAEwAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAMXWBPXAAAAAAAAAAAAAAAAAAAAAAhAAAAAAAdAAACAAAAAAAA" +
      "AAAAAAAAAABkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRk" +
      "ZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRk" +
      "ZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRk" +
      "ZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRkZGRk" +
      "ZGRkZGRkJGRkZGRkZGRkZGRkZGRkZGRhYmRkZGRkZGRkZGRkZGRkZGRk" +
      "ZGRkZBcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAGRkAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAD/HwAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAP///z8AAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAA//////9/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP///wMAAP8PAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAA//////////8PAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAD//////////38AAAAAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AOCf+f///e0jAAAB4AMAAAAAAAAAAAAAAAAAAAAAAAAA//////8A////" +
      "////DwAAAAAAAAAAAAAAAAAAAAAAAAD///////9/AP//PwD/AAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP//AwAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAA////fwAAAAAAAAAAAAAAAAAAAACE/C8+UL3/" +
      "8+BD/////////wMAAAAAAAAAAAAAAAAAAID//////w8A/////////wEA" +
      "DAAAAAAAAAAAAAAAAAAAAQAAAP//DwD//v///x8AAAAfAAAAAAAAAAAA" +
      "AAAAAAD///////8AAA8A//v7///g//8AAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AAAAAAAAAAAAwP///w8AAAAAAAAAAAAAAAAA/////////////////wf/" +
      "H/8B/wMAAAAAAAAAAAAAAAD/////////////////////////AwAAAAAA" +
      "AAAAAAAAAAAAAAAAAAAAAAAAAAAA84P/A/8fAAAAAAAAAAAAAAAA////" +
      "//////8fAAEAAAAAAAAA+P8AAAAAAAAAAAAAAAD/////////////////" +
      "/////////wMAAAAAAAAAAAAAAP//fwD///////8fAAAAAAD/A/8DgAAA" +
      "AAAAAAAAAAAA/////////////////////////z//AwAAAAAAAAAAAAD/" +
      "//////8/AP//P////wf///8DAAD+AAAAAAAAAAAAAP//PwQQAQAA////" +
      "AQAAAAAAAAAA//8fAAAAAAAAAAAA////////////////////////////" +
      "/z8AAAAAAAAAAADv////lv73CoTqlqqW9/de//v/D+77/w8AAAAAAAAA" +
      "AAAAAAD/AwAAAP/+/wAAAAD/AwAAAAD+/wAAAAAAAAAA////////////" +
      "////////////////////AAAAAAAAAAD///////8AABAA/wMAAAAA////" +
      "//8HAAD/AwAAAAAAAP///////////////////////////////5//AAAA" +
      "AAAA/////w8A////B/////8/AP///z//////D/8+AAAAAAD/////////" +
      "/////////////////////////z8AAAAAAP//////////////////////" +
      "////////////fwAAAAAAAAAAAAAAAAAAAAAAAAAAAP///////wAAsAD/" +
      "AwAAAAD/////////////////P/////////////////8DAAAAAP///38A" +
      "AAAAwP////8/HwD//////w////8D/wcAAAAAAAAAAAAAAAAAAAAAAAAA" +
      "AP//////fwAAAAAADwAAAAAAAP8D/v//B/7//wfA/////////////3/8" +
      "/PwcAAAAAP////+/IP////////+AAAD//38Af39/f39/f38AAAAA/v//" +
      "////DQB/AP8DAAAAAJYl8P6u7A0gXwD/8wAAAADg//////8PAOAP/wMA" +
      "AAAA+P///wHA////////PwAAAP////////8B////f/8DAAAAAAAAAAAA" +
      "AAAA////PwAA////////////////////////////////w/8DAB9QAAAB" +
      "AO/+//8PAP8AAAD///9//////wAAAAD//v//H/gAAODf/f////8nAEAA" +
      "gMP/P/zg/3/8///7L38AAADA/wAA/x////8PAAD//////38AgP///z//" +
      "////////////AADg3/3///3/IwAAAAfD/wB/4N/9///97yMAAABAw/8G" +
      "AP////////7///9/Av7/////AAAAAAAAAAAA////BwcA4J/5///97SMA" +
      "AACww//+AOjHPdYYx/8DAAABAMD/BwD//////wEAAPcP/wP//3/E////" +
      "////Yj4FAAA4/wccAPj///9/AMD/AAD/////RwD4//////8HAB4A/xf+" +
      "/x8AAAD/A///////////////AP//////Bf//////////PwD/////DwAA" +
      "AP/j//////8/AAAAAAAAAAAAAAAAAN5jAP////////////////+f///+" +
      "//8H////////////x/8BAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA////" +
      "/////wHgh/n///1tAwAAAF7A/xwA4L/7///97SMAAAEAw/8AAvD/////" +
      "//8jAAAB/8P//v/hn/n///3FIwBAALDD//MD///7//8PAAAAAAAAAAAA" +
      "AH+9/7//Af//////fwAA/wN+fn4Af3////////c/AP//////////////" +
      "////BwD/A/j///////8AAAD8////AAD4//////8AAAAA////Af8D/98D" +
      "AP//AwD//wMA/98BAP///////w8AAACAEP8D/wMAAP3///8AAADg////" +
      "/////////z8AAgD//////wcwBP/v//9///+3/z//PwAAAAD/////////" +
      "//////////8H/////////z8AAP///////////P///////wAAAAAA/w8A" +
      "AAAAAAAAAAAAAAAAAAAA////H////////wEA/v//D///////////////" +
      "////////////DwD//3/4//////8P//8/P/////8/P/+q////P///////" +
      "/99f3B/PD/8f3B8AAAAAAAAAAAAAAAAAAN//////////////////////" +
      "H///////f///////f/////////////////////8feAwgu/f//wcAPwD/" +
      "//////8PAPz//////w8AAAD/AwAA/Cj//z3//////////wcA/v8f//8A" +
      "AP////////////8/P///////////////////////HwAAAAAAAAAA////" +
      "//8//////z8A//9/AAAA////H/D//////wcAAID/A9///38AAAAAAAAA" +
      "AAAAAAAAAAAAAAAAAP////////////8HgAAAAAD//////wcAAP/D/v//" +
      "////////////LwBgwP+f//////////////////////////8//////f//" +
      "9/////f//////wcAgP8DPzxiwOH/A0D/A/////+/IP//////9+AAAAD+" +
      "Az4f/v///////////3/g/v/////////////3P/3/////v5H//z////9/" +
      "/v///3+A/wAAAAAAAP//N/j///////////8BAAAAAAAA////////BwD/" +
      "//////8H/AAAAAAAAP8D/v//B/7//wcAAAAAAAQsdv//f////3//AACA" +
      "//z////////////////5////P/8AAAAAAAAAgP8AAAAAAAAAAAAAAAAA" +
      "AN+8QNf///v///////////+//+D/////P/7/////////////fzwA////" +
      "BwAAAAAAAP//AAAAAAAAAAAAAAAA/////////w8AAAAAAAAAAAD8////" +
      "//////////89fz3//////z3/////PX89/3///////38A+KD//X9f2///" +
      "//////////////8DAAAA+P//////////D////wMAAAAAAAAAAP//////" +
      "///w///8/////////9/////f//9/////f/////3////9///3z///////" +
      "///////////////f///////////fZN7/6+//////////////////////" +
      "/////////wP8////////////////////////////////////fwAA////" +
      "/////////////////7/n39////97X/z9////////////////////////" +
      "////////////HwD///////////////////////////////////8/////" +
      "//////////////////////////////////7/////////////////////" +
      "////////////////////////////////////////////////////////" +
      "//////8="
    ).unpack('m').first
  end

  class Markup_Constructor < Array
    def node type, **attr
      return push(OpenStruct.new(type: type, **attr))
      # [[Array#push]] will return self, allowing [[node]] calls
      # to be chained.
    end

    def plain data
      return node(MU_PLAIN, data: data)
    end

    def space data = nil
      return node(MU_SPACE, data: data)
    end

    def words s
      s.split(/(\s+)/, -1).each_with_index do |part, i|
        # Note that 0 is [[MU_PLAIN]] and 1 is [[MU_SPACE]].
        node(i & 1, data: part)
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
    attr_reader :width
    attr_accessor :vsep
    attr_reader :pseudographics

    def initialize port = $stdout,
        width: 80,
        pseudographics: UNICODE_PSEUDOGRAPHICS,
        palette: DEFAULT_PALETTE
      super()
      @port = port
      @width = width
      @pseudographics = pseudographics
      @palette = palette
      @hang = OpenStruct.new(
        content: '',
        width: 0)
      @curpos = 0
      # If [[@curspace]] is set or [[@curword.content]] is not
      # empty, we say the wrapper is in a /pending word/ state.
      # This is mutually exclusive with [[@pending_hang]].
      @curspace = nil
      @curword = OpenStruct.new(
        content: '',
        width: 0)
      # If [[@pending_hang]] is set, we say the wrapper is in a
      # /pending hang/ state.  In this state, nothing of the
      # current line has been output yet, but the indentation is
      # supposed to be output immediately before anything else
      # gets output, including a linebreak.  It is possible to
      # change [[@hang]] during this time.  This way, if the
      # thunk supplied to [[hang]] calls [[linebreak]]
      # immediately before returning, the line gets properly
      # broken, but the subsequent line will be prefixed with
      # the hang that was in effect outside this particular
      # [[hang]] call.
      @pending_hang = false
      @curmode = @palette.null
      # [[@vsep]] keeps track of consecutive blank lines.
      # Since we subscribe to zero-one-many counting, and the
      # amount of separation at the top of file is infinite,
      # we'll initialise it to 2.
      @vsep = 2
      return
    end

    def add_plain data
      _execute_pending_hang
      # Are we going to exceed [[@width]] with this addition?
      if @curspace and @curpos + data.length > @width then
        # yes, convert [[@curspace]] into a linebreak
        @port.puts @palette.null
        @port.print @hang.content
        @port.print @curmode
        @curspace = nil
        @curpos = @hang.width + @curword.width
      end
      @curword.content << data
      @curword.width += data.length
      @curpos += data.length

      # Since we're writing horizontally now, there's no vertical
      # separation anymore.  In fact, there's so little separation
      # that adding one linebreak would mean zero blank lines.
      @vsep = -1

      return
    end

    def add_space data = ' '
      _execute_pending_hang
      @port.print @curspace.content if @curspace
      @port.print @curword.content
      @curspace = OpenStruct.new(
        content: data,
        width: data.length)
      @curword = OpenStruct.new(
        content: '',
        width: 0)
      @curpos += data.length

      # Like with [[add_plain]], we'll clear [[@vsep]] here.
      @vsep = -1
      return
    end

    def linebreak
      _execute_pending_hang
      @port.print @curspace.content if @curspace
      @port.print @curword.content
      @port.puts @palette.null
      @curspace = nil
      @curword = OpenStruct.new(
        content: '',
        width: 0)
      @curpos = 0
      @pending_hang = true
      @vsep += 1 unless @vsep >= 2
      return
    end

    def vseparate amount = 1
      # In zero-one-many counting, we can't count any higher than
      # 'many'.
      raise 'too much separation needed' \
          unless amount <= 2
      while @vsep < amount do
        linebreak
      end
      return
    end

    def _execute_pending_hang
      if @pending_hang then
        raise 'assertion failed' \
            if @curspace or !@curword.content.empty?
        @port.print @hang.content
        @curpos += @hang.width
        @port.print @curmode
        @pending_hang = false
      end
      return
    end
    private :_execute_pending_hang

    def add_node node,
        symbolism: Fabricator.default_symbolism
      case node.type
      when MU_PLAIN then
        add_plain node.data

      when MU_SPACE then
        add_space node.data || ' '

      when MU_SPECIAL_ATOM then
        case node.subtype
          when SA_NBSP then add_plain ' '
          when SA_NDASH then add_plain '-'
          when SA_MDASH then add_plain '--'
          when SA_ELLIPSIS then add_plain '...'
          else raise 'assertion faile'
        end

      when MU_BOLD, MU_ITALIC, MU_UNDERSCORE, MU_MONOSPACE then
        styled Fabricator::MARKUP2CTXT_STYLE[node.type] do
          add_nodes node.content, symbolism: symbolism
        end

      when MU_MENTION_CHUNK then
        add_plain symbolism.chunk_name_delim.begin
        add_nodes Fabricator.parse_markup(node.name, PF_LINK),
            symbolism: symbolism
        add_plain symbolism.chunk_name_delim.end

      when MU_LINK then
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
        # Uh-oh, a bug: the parser has generated a node of a
        # type unknown to the weaver.
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

    def hang column = nil, filler = ''
      # convert the preceding whitespace, if any, into 'hard'
      # space not subject to future wrapping
      if @curspace then
        @port.print @curspace.content
        @curspace = nil
      end

      prev_hang = @hang
      begin
        @hang = OpenStruct.new(width: column || @curpos)
        new_hang_width = @hang.width - prev_hang.width
        raise 'assertion failed: too much filler' \
            if filler.length > new_hang_width
        @hang.content = prev_hang.content +
            '%%-%is' % new_hang_width % filler
        yield
      ensure
        @hang = prev_hang
      end
      return
    end

    def hangindent
      return @hang.width
    end

    def styled sequence_name
      _execute_pending_hang
      sequence = @palette[sequence_name]
      raise 'unknown palette entry' unless sequence
      prev_mode = @curmode
      begin
        @curmode = sequence
        @curword.content << sequence
        yield
      ensure
        @curmode = prev_mode
        @curword.content << prev_mode
        @vsep = -1
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

  MARKUP2CTXT_STYLE = { # node type tag => ctxt style name
    MU_BOLD => :bold,
    MU_ITALIC => :italic,
    MU_UNDERSCORE => :underscore,
    MU_MONOSPACE => :monospace,
  }

  UNICODE_PSEUDOGRAPHICS = OpenStruct.new(
    bullet: [0x2022].pack('U*'),
    initial_chunk_margin: [0x2500, 0x2510].pack('U*'),
    chunk_margin: [0x0020, 0x2502].pack('U*'),
    block_margin: "  ",
    final_chunk_marker:
        ([0x0020, 0x2514] + [0x2500] * 3).pack('U*'),
    thematic_break_char: [0x2500].pack('U*'),
    subplot_leadin: ([0x256D] + [0x2500] * 3).pack('U*'),
    subplot_margin: [0x2502, 0x0020].pack('U*'),
    subplot_leadout: ([0x2570] + [0x2500] * 3).pack('U*'),
  )

  ASCII_PSEUDOGRAPHICS = OpenStruct.new(
    bullet: "-",
    initial_chunk_margin: "+ ",
    chunk_margin: "| ",
    block_margin: "  ",
    final_chunk_marker: "----",
    thematic_break_char: "-",
    subplot_leadin: ",---",
    subplot_margin: "| ",
    subplot_leadout: "`---",
  )

  DEFAULT_PALETTE = OpenStruct.new(
    monospace: "\e[38;5;71m",
    bold: "\e[1m",
    italic: "\e[3m",
    underscore: "\e[4m",
    root_type: "\e[4m",
    seq_no: "\e[3m",
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
      @port.puts '<main>'
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
      @port.puts '</main>'
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
      @fabric.presentation.each do |element|
        html_presentation_element element
        @port.puts
      end
      return
    end

    def html_presentation_element element
      case element.type
      when OL_TITLE then
        @port.print '<h%i' % (element.level + 1)
        @port.print " id='%s'" % "T.#{element.number}"
        @port.print '>'
        @port.print "#{element.number}. "
        htmlify element.content
        @port.puts '</h%i>' % (element.level + 1)
      when OL_SUBPLOT
        @port.puts "<aside class='maui-subplot'>"
        element.elements.each_with_index do |element, i|
          @port.puts unless i.zero?
          html_presentation_element element
        end
        @port.puts '</aside>'
      when OL_SECTION then
        rubricated = !element.elements.empty? &&
            element.elements[0].type == OL_RUBRIC
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
        if subelement then
          case subelement.type
            when OL_PARAGRAPH then
              @port.print " "
              htmlify subelement.content
              start_index += 1
            when OL_DIVERT then
              @port.print " "
              html_chunk_header subelement, 'maui-divert',
                  tag: 'span'
              warnings = subelement.warnings
              start_index += 1
            # FIXME: also support chunks here
          end
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
      when OL_THEMBREAK then
        @port.puts "<hr />"
      when OL_NOP then
        # no operation
      when OL_IMPLICIT_TOC, OL_EXPLICIT_TOC then
        html_toc
      else raise 'data structure error'
      end
      return
    end

    def html_section_part element
      case element.type
      when OL_PARAGRAPH then
        @port.print "<p>"
        htmlify element.content
        @port.puts "</p>"

      when OL_LIST then
        html_list element.items

      when OL_DIVERT then
        html_chunk_header element, 'maui-divert'
        @port.puts
        html_warning_list element.warnings, inline: true

      when OL_CHUNK, OL_DIVERTED_CHUNK then
        @port.print "<div class='maui-chunk"
        @port.print " maui-initial-chunk" if element.initial
        @port.print " maui-final-chunk" if element.final
        @port.print "'>"
        if element.type == OL_CHUNK then
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

      when OL_BLOCK then
        @port.print "<pre class='maui-block'>"
        element.lines.each_with_index do |line, i|
          @port.puts unless i.zero?
          @port.print line.to_xml
        end
        @port.puts "</pre>"

      when OL_BLOCKQUOTE then
        @port.print "<blockquote class='maui-blockquote'>"
        element.elements.each do |child|
          html_section_part child
          @port.puts
        end
        @port.puts "</blockquote>"

      when OL_THEMBREAK then
        @port.puts "<hr />"
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
          if entry.type == OL_RUBRIC then
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
          when OL_TITLE then
            @port.print "#{entry.number}. "
            @port.print "<a href='#T.#{entry.number}'>"
            htmlify entry.content
            @port.print "</a>"
          when OL_RUBRIC then
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
        @port.puts "</li></ul>" * last_level
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
      htmlify Fabricator.parse_markup(element.name, PF_LINK)
      if element.seq then
        @port.print " "
        @port.print "<span class='maui-chunk-seq'>"
        @port.print "#"
        @port.print element.seq.to_s
        @port.print "</span>"
      end
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
          htmlify Fabricator.parse_markup(node.name, PF_LINK)
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
        when MU_PLAIN then
          @port.print node.data.to_xml

        when MU_SPACE then
          @port.print((node.data || ' ').to_xml)

        when MU_SPECIAL_ATOM then
          case node.subtype
            when SA_NBSP then @port.print '&nbsp;'
            when SA_NDASH then @port.print '&ndash;'
            when SA_MDASH then @port.print '&mdash;'
            when SA_ELLIPSIS then @port.print '&hellip;'
            else raise 'assertion failed'
          end

        when MU_BOLD, MU_ITALIC, MU_UNDERSCORE,
            MU_MONOSPACE then
          html_tag = Fabricator::MARKUP2HTML[node.type]
          @port.print "<%s>" % html_tag
          htmlify node.content
          @port.print "</%s>" % html_tag

        when MU_MENTION_CHUNK then
          @port.print "<span class='maui-chunk-mention'>"
          @port.print @symbolism.chunk_name_delim.begin
          htmlify Fabricator.parse_markup(node.name, PF_LINK)
          @port.print @symbolism.chunk_name_delim.end
          @port.print "</span>"

        when MU_LINK then
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

  MARKUP2HTML = { # node type tag => HTML tag
    MU_MONOSPACE => 'code',
    MU_BOLD => 'b',
    MU_ITALIC => 'i',
    MU_UNDERSCORE => 'u',
  }
end

class << Fabricator
  include Fabricator
  def parse_fabric_file input, integrator,
      suppress_indexing: false,
      suppress_narrative: false,
      nesting_mode: nil,
      filename: nil,
      first_line: 1
    raise 'assertion failed' \
        unless [nil, :blockquote, :subplot].include?(
            nesting_mode)
    vp = Fabricator::Vertical_Peeker.new input,
        filename: filename,
        first_line: first_line

    parser_state = OpenStruct.new(
        vertical_separation: nil,
            # the number of blank lines immediately preceding
            # the element currently being parsed
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
        if nesting_mode != :blockquote then
          integrator.force_section_break
        else
          # FIXME: generate a warning about ignoring the section
          # break because of blockquote mode
        end
      end
      element_location = vp.location_ahead
      line = vp.peek_line
      if line =~ /^\s+/ then
        if !integrator.in_list? or
            vp.peek_line !~ /^
                (?<margin> \s+ )
                - (?<separator> \s+ )
                /x then
          body_location = vp.location_ahead
          element = vp.get_indented_lines_with_skip
          element.type = OL_BLOCK
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
            type: OL_ITEM,
            lines: lines,
            content: parse_markup(lines.map(&:strip).join ' '),
            indent: margin.length,
            loc: element_location)
        end

      elsif nesting_mode != :blockquote and line =~ /^<<\s*
          (?: (?<root-type> \.file|\.script) \s+ )?
          (?<raw-name> [^\s].*?)
          (?: \s* \# (?<seq> \d+) )?
          \s*>>:$/x then
        name = canonicalise $~['raw-name']
        vp.get_line
        element = OpenStruct.new(
          type: OL_DIVERT,
          root_type: $~['root-type'],
          name: name,
          seq: $~['seq'] && $~['seq'].to_i,
          header_loc: element_location)

        body_location = vp.location_ahead
        body = vp.get_indented_lines_with_skip
        if body then
          element.type = OL_CHUNK
          element.lines = body.lines
          element.indent = body.indent
          element.body_loc = body_location
          element.initial = element.final = true
        end

      elsif line =~ /^---+$/ or line =~ /^(\*\s*){3,}$/ or
          line =~ /^(_\s*){3,}$/ then
        vp.get_line
        element = OpenStruct.new type: OL_THEMBREAK

      elsif line =~ /^-\s/ then
        # We'll discard the leading dash but save the following
        # whitespace.
        lines = [vp.get_line[1 .. -1]]
        while !vp.eof? and
            vp.peek_line != '' and
            vp.peek_line !~ /^\s*-\s/ do
          lines.push vp.get_line
        end
        element = OpenStruct.new(
          type: OL_ITEM,
          lines: lines,
          content: parse_markup(lines.map(&:strip).join ' '),
          indent: 0,
          loc: element_location)

      elsif line[0] == ?> then
        start_location = vp.location_ahead
        content = vp.parse_block ?>
        # Blockquotes are purely narrative nodes, so if narrative
        # processing is suppressed, there's no point in parsing
        # their content.
        unless suppress_narrative then
          # We'll initiate the blockquote by constructing a blank
          # [[OL_BLOCKQUOTE]] node and sending it to the integrator.
          integrator.integrate OpenStruct.new(
                  type: OL_BLOCKQUOTE,
                  elements: []),
              suppress_indexing: suppress_indexing
          parse_fabric_file StringIO.new(content), integrator,
              suppress_indexing: suppress_indexing,
              nesting_mode: :blockquote,
              filename: start_location.filename,
              first_line: start_location.line
          integrator.end_blockquote
        end
        next
            # since we have no [[element]] to be handled after the
            # massive [[if ...]] construct, we'll have to restart
            # the loop manually here

      elsif nesting_mode != :blockquote and line[0] == ?| then
        start_location = vp.location_ahead
        content = vp.parse_block ?|

        integrator.integrate OpenStruct.new(
                type: OL_SUBPLOT,
                elements: []),
            suppress_narrative: suppress_narrative,
            suppress_indexing: suppress_indexing
        parse_fabric_file StringIO.new(content), integrator,
            suppress_indexing: suppress_indexing,
            nesting_mode: :subplot,
            filename: start_location.filename,
            first_line: start_location.line
        integrator.end_subplot
        next
            # since we have no [[element]] to be handled after the
            # massive [[if ...]] construct, we'll have to restart
            # the loop manually here

      elsif nesting_mode != :blockquote and line =~ /^\.\s+/ then
        name = $'
        element = OpenStruct.new(
            type: OL_INDEX_ANCHOR,
            name: name)
        vp.get_line

      elsif nesting_mode.nil? and line.downcase == '.toc' then
        element = OpenStruct.new type: OL_EXPLICIT_TOC
        vp.get_line

      elsif line =~ /^[^\s]/ then
        lines = []
        while vp.peek_line =~ /^[^\s]/ and
            vp.peek_line !~ /^-\s/ do
          lines.push vp.get_line
        end
        mode_flags_to_suppress = 0
        if nesting_mode.nil? and lines[0] =~ /^(==+)(\s+)/ then
          lines[0] = $2 + $'
          element = OpenStruct.new(
            type: OL_TITLE,
            level: $1.length - 1,
            loc: element_location)
          mode_flags_to_suppress |= PF_LINK

        elsif nesting_mode.nil? and lines[0] =~ /^\*\s+/ then
          lines[0] = $'
          element = OpenStruct.new(
              type: OL_RUBRIC,
              loc: element_location)

        else
          element = OpenStruct.new(
              type: OL_PARAGRAPH,
              loc: element_location)
        end
        element.lines = lines
        element.content =
            parse_markup(lines.map(&:strip).join(' '),
            mode_flags_to_suppress)
      end
      integrator.integrate element,
          suppress_indexing: suppress_indexing,
          suppress_narrative: suppress_narrative
    end
    if nesting_mode.nil? then
      integrator.force_section_break
      integrator.clear_diversion
    end
    return
  end

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

  def parse_markup s, suppress_modes = 0
    ps = Fabricator::Pointered_String.new s
    stack = Fabricator::Markup_Parser_Stack.new suppress_modes
    while ps.pointer < s.length do
      if ps.at? "[[" and
          # FIXME: we should be looking for two right brackets with
          # no Unicode combining characters following, not just two
          # right brackets
          end_offset = s.index("]]", ps.pointer + 2) then
        while ps[end_offset + 2] == ?] do
          end_offset += 1
        end
        stack.last.content.node MU_MONOSPACE,
            content: Fabricator.markup.
                words(ps[ps.pointer + 2 ... end_offset].strip)
        ps.pointer = end_offset + 2

      elsif stack.last.mode & PF_BOLD != 0 and
          ps.biu_starter? ?* then
        stack.spawn '*', PF_BOLD, PF_END_BOLD
        ps.pointer += 1

      elsif stack.last.mode & PF_ITALIC != 0 and
          ps.biu_starter? ?/ then
        stack.spawn '/', PF_ITALIC, PF_END_ITALIC
        ps.pointer += 1

      elsif stack.last.mode & PF_UNDERSCORE \
              != 0 and
          ps.biu_starter? ?_ then
        stack.spawn '_', PF_UNDERSCORE, PF_END_UNDERSCORE
        ps.pointer += 1

      elsif stack.last.mode & PF_END_BOLD != 0 and
          ps.biu_terminator? ?* then
        stack.ennode MU_BOLD, PF_END_BOLD
        ps.pointer += 1

      elsif stack.last.mode & PF_END_ITALIC != 0 and
          ps.biu_terminator? ?/ then
        stack.ennode MU_ITALIC, PF_END_ITALIC
        ps.pointer += 1

      elsif stack.last.mode & PF_END_UNDERSCORE != 0 and
          ps.biu_terminator? ?_ then
        stack.ennode MU_UNDERSCORE, PF_END_UNDERSCORE
        ps.pointer += 1

      elsif stack.last.mode & PF_LINK != 0 and
          ps.biu_starter? ?< then
        stack.spawn '<', PF_LINK, PF_END_LINK
        stack.last.start_offset = ps.pointer
        ps.pointer += 1

      elsif stack.last.mode & PF_END_LINK != 0 and
          ps.at? '|' and
          # FIXME: we should be looking for a [[>]] with no Unicode
          # combining character(s) following, not just a right
          # broket
          end_offset = s.index(?>, ps.pointer + 1) then
        target = ps[ps.pointer + 1 ... end_offset]
        # Remove the 'soft hyphenation' for URLs
        # FIXME: but consider potential Unicode combining characters
        # following the last space
        target = target.gsub(/%\s+/, '')
        if link_like? target then
          stack.ennode MU_LINK, PF_END_LINK,
              target: target
          ps.pointer = end_offset + 1
        else
          # False alarm: this is not a link, after all.
          stack.cancel_link
          stack.last.content.plain '|'
          ps.pointer += 1
        end

      elsif stack.last.mode & PF_END_LINK != 0 and
          ps.at? '>' then
        j = stack.rindex do |x|
          x.term_type == PF_END_LINK
        end
        target = ps[stack[j].start_offset + 1 ... ps.pointer]
        # Remove the URL's 'soft hyphenation' but keep it for
        # the link's face
        # FIXME: but consider potential Unicode combining characters
        # following the last space
        solidified_target = target.gsub(/%\s+/, '')
        if link_like? solidified_target then
          stack[j .. -1] = []
          stack.last.content.node MU_LINK,
              implicit_face: true,
              target: solidified_target,
              content: Fabricator.markup.plain(target)
        else
          # False alarm: this is not a link, after all.
          stack.cancel_link
          stack.last.content.plain '>'
        end
        ps.pointer += 1

      elsif ps.at? ' ' then
        ps.pointer += 1
        while ps.at? ' ' do
          ps.pointer += 1
        end
        stack.last.content.space
        if ps.at? '- ' then
          stack.last.content.node MU_SPECIAL_ATOM,
              subtype: SA_NDASH
          ps.pointer += 1 # leave the following space in place
        end

      elsif ps.at? "\u00A0" then
        stack.last.content.node MU_SPECIAL_ATOM,
            subtype: SA_NBSP
        ps.pointer += 1

      elsif ps.at? "--" then
        stack.last.content.node MU_SPECIAL_ATOM,
            subtype: SA_MDASH
        ps.pointer += 2

      elsif ps.at? "\u2014" then
        stack.last.content.node MU_SPECIAL_ATOM,
            subtype: SA_MDASH
        ps.pointer += 1

      elsif ps.at? "..." then
        stack.last.content.node MU_SPECIAL_ATOM,
            subtype: SA_ELLIPSIS
        ps.pointer += 3

      elsif ps.at? "\u2013" then
        stack.last.content.node MU_SPECIAL_ATOM,
            subtype: SA_NDASH
        ps.pointer += 1

      else
        j = ps.pointer + 1
        while j < s.length and
            !" \$*-./<>[_|~\u00A0\u2013\u2014".include? ps[j] do
          j += 1
        end
        stack.last.content.plain(
            String.new(ps[ps.pointer ... j]))
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

  def canonicalise raw_name
    name = ''
    raw_name.strip.split(/(\[\[.*?\]*\]\])/, -1).
        each_with_index do |part, i|
      part.gsub! /\s+/, ' ' if i.even?
      name << part
    end
    return name
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

  def load_fabric input, chunk_size_limit: 24,
      bases: []
    integrator = Fabricator::Integrator.new
    bases.each do |base|
      File.open base, 'r', encoding: Encoding::UTF_8 do |port|
        parse_fabric_file port, integrator,
            suppress_narrative: true,
            suppress_indexing: true
      end
    end
    raise 'assertion failed' \
        unless integrator.section_count.zero?
    parse_fabric_file input, integrator
    integrator.tangle_roots
    integrator.check_chunk_sizes(chunk_size_limit)
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
    fabric.presentation.each do |element|
      wr.vseparate
      weave_ctxt_plot_element element, fabric, wr,
          symbolism: symbolism
    end
    unless fabric.index.empty? then
      wr.vseparate 2
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

  def weave_ctxt_plot_element element, fabric, wr,
      symbolism: default_symbolism
    case element.type
    when OL_TITLE then
      wr.styled :section_title do
        wr.vseparate 2
        wr.add_plain "#{element.number}."
        wr.add_space
        wr.hang do
          wr.add_nodes element.content, symbolism: symbolism
        end
      end
      wr.linebreak # line terminator

    when OL_SUBPLOT then
      wr.add_pseudographics :subplot_leadin
      wr.linebreak
      wr.add_pseudographics :subplot_margin
      # A subplot's ends are already separated.
      wr.vsep = 2
      wr.hang wr.hangindent + 2,
          wr.pseudographics[:subplot_margin] do
        element.elements.each do |child|
          wr.vseparate
          weave_ctxt_plot_element child, fabric, wr,
              symbolism: symbolism
        end
      end
      wr.add_pseudographics :subplot_leadout
      wr.linebreak

    when OL_SECTION then
      # [[element.elements]] can be empty if a section
      # contains index anchor(s) but no content.  This is a
      # pathological case, to be sure, but it can happen, so
      # we'll need to check.
      rubricated = !element.elements.empty? &&
          element.elements[0].type == OL_RUBRIC

      wr.vseparate
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
        when OL_PARAGRAPH, OL_DIVERT, OL_CHUNK then
          wr.add_space
          weave_ctxt_section_part starter, fabric, wr,
              symbolism: symbolism
          start_index += 1
        else
          wr.linebreak
        end
      end

      element.elements[start_index .. -1].each do |child|
        wr.vseparate
        weave_ctxt_section_part child, fabric, wr,
            symbolism: symbolism
      end

      unless (element.warnings || []).empty? then
        weave_ctxt_warning_list element.warnings, wr,
            inline: true, indent: false
      end

    when OL_THEMBREAK then
      wr.width.times do
        wr.add_pseudographics :thematic_break_char
      end
      wr.linebreak

    when OL_NOP then
      # no operation

    when OL_IMPLICIT_TOC, OL_EXPLICIT_TOC then
      weave_ctxt_toc fabric.toc, wr,
          symbolism: symbolism
    else raise 'data structure error'
    end
    return
  end

  def weave_ctxt_section_part element, fabric, wr,
      symbolism: default_symbolism
    case element.type
    when OL_PARAGRAPH then
      wr.add_nodes element.content, symbolism: symbolism
      wr.linebreak

    when OL_DIVERT, OL_CHUNK, OL_DIVERTED_CHUNK then
      if element.type & OLF_HAS_HEADER != 0 then
        weave_ctxt_chunk_header element, wr,
            symbolism: symbolism
        weave_ctxt_warning_list element.warnings, wr,
            inline: true
      end
      if element.type & OLF_HAS_CODE != 0 then
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

    when OL_LIST then
      _weave_ctxt_list element.items, wr,
          symbolism: symbolism

    when OL_BLOCK then
      weave_ctxt_block element, wr

    when OL_BLOCKQUOTE then
      wr.add_plain '> '
      wr.hang wr.hangindent + 2, '>' do
        element.elements.each_with_index do |child, i|
          wr.linebreak unless i.zero?
          weave_ctxt_section_part child, fabric, wr,
              symbolism: symbolism
        end
      end

    when OL_THEMBREAK then
      (wr.width - wr.hangindent).times do
        wr.add_pseudographics :thematic_break_char
      end
      wr.linebreak
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
              PF_LINK),
          symbolism: symbolism
      if element.seq then
        wr.add_space
        wr.styled :seq_no do
          wr.add_plain '#'
          wr.add_plain element.seq.to_s
        end
      end
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
      wr.add_nodes Fabricator.parse_markup(node.name, PF_LINK),
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
          transcluders.map{|ref|
            m = markup
            m.node(MU_MENTION_CHUNK, name: ref.name)
            # [[ref.section_number]] can be [[nil]] if the
            # transcluder belongs to a unwoven fabric file as
            # unwoven sections are not numbered.
            unless ref.section_number.nil? then
              m.space.
                  plain("(").
                  node(MU_LINK,
                    content: markup.
                        plain(symbolism.section_prefix +
                            ref.section_number.to_s),
                    target: "#S.#{ref.section_number}",
                    implicit_face: true).
                  plain(")")
            end
            m
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
    result = markup
    items.each_with_index do |item, i|
      unless i.zero? then
        unless items.length == 2 then
          result.plain ','
        end
        result.space
        if i == items.length - 1 then
          result.plain 'and'
          result.space
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
      wr.vseparate 2
      wr.styled :section_title do
        wr.add_plain 'Contents'
      end
      wr.linebreak; wr.linebreak
      rubric_level = 0
      toc.each do |entry|
        case entry.type
        when OL_TITLE then
          rubric_level = entry.level - 1 + 1
          wr.add_plain '  ' * (entry.level - 1)
          wr.add_plain entry.number + '.'
          wr.add_space
          wr.hang do
            wr.add_nodes entry.content, symbolism: symbolism
          end

        when OL_RUBRIC then
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
