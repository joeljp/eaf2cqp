require 'nokogiri'
require 'date'


files = ARGV

#transcriptions = []



class Transcription

  class Annotation
    attr_accessor :problem_annotation_ids, :annotation_id, :participant, :start, :stop, :column, :problem

    @@column_indices = false

    @@multi_schema = false

    @@ncolumns = 1

    def self.configured?
      @@column_indices
    end

    def self.get_cqp_columns
      @@cqp_columns
    end

    def self.set_type!(k,v)
      if !@@column_indices
        @@column_indices = {}
      end
      @@ncolumns += 1 unless v == 0
      @@column_indices[k] = v
      @@cqp_columns = @@column_indices
    end


    def self.init_cqp_cols(cnf)
      @@multi_schema = true
      cnf = cnf.split(/\n/)    
      column_array = cnf.shift.split
      if !column_array.member?("nocat")
        column_array.push("nocat")
      end
      @@ncolumns = column_array.length

      div_column_index = column_array.find_index("nocat")
      @@column_indices = Hash.new { |hash, key| hash[key] = div_column_index } # fallback column for unknown tags

      column_array.each_index {|j| @@column_indices[column_array[j]] = j}
      @@cqp_columns = @@column_indices.clone
      cnf.each do |line|
        cat, *atts = *line.split
        atts.each { |att| @@column_indices[att] = column_array.find_index(cat) }
      end
    end

    def self.problems
      @@problem_annotation_ids.each do |k,v|
        v.write
      end
    end

    @@problem_annotation_ids = {}

    def initialize(participant, id, time_slot_ref1, time_slot_ref2, type, text)
      @problem = false
      @participant = participant
      @annotation_id = id
      text = text.split(/[ ]/) # should perhaps include underscores?!?
      @length = text.length
      @column = Hash.new
      @column[type] = text
      @start = Transcription.time_slots(time_slot_ref1)
      @stop =  Transcription.time_slots(time_slot_ref2)
    end

    def add(type, text)
      text = text.split
      length = text.length
      if length != @length
        @problem = true
        @@problem_annotation_ids[@annotation_id] = self
      end
      @column[type] = text
    end

    def text
      text = "\n"
      @length.times do |pos|
        out = ["_"]*@@ncolumns
        just_a_marker = true
        @column.keys.each do |type|
          if type != 'multi'
            out[@@column_indices[type]] = @column[type][pos]
          else
            if !@@multi_schema
              out[@@column_indices['multi']] = @column[type][pos]
              next
            end
            tags = @column[type][pos].split(/[_\+\/]/)
            tags.each do |tag|
              out[@@column_indices[tag]] = tag
            end
          end
        end
        out.each {|e| just_a_marker = false if e !~ /\+\w\(?|\)|_/}
        next if just_a_marker #!!!!!!!!!!!!!!!! this is the bit i put in to get rid of those irritating +u(tags)!!
        text += out.join("\t") + "\n"
      end
      text + "      "
    end

  end




  @@chronology = Hash.new #EACH Object should have its own chronology. This should be list of transcriptions!

  def self.cqp_xml
    corpus_attributes = Annotation.get_cqp_columns
    corpus_attributes[:corpus] = "corpus"
    corpus_attributes[:date] = DateTime.now
    @@builder = Nokogiri::XML::Builder.new(:encoding => 'UTF-8') do |xml|
      xml.corpus( corpus_attributes ) do |c|
        @@chronology.each_key do |file|
          c.transcription( :file => file) do |transcription|
            transcription(transcription, file)
          end
        end
      end
    end
    @@builder.to_xml
  end



  def self.transcription(xml, file)
    transcription = @@chronology[file]
    transcription.keys.sort{ |a,b| a.sub(/^[a-z]+/, "").to_i <=> b.sub(/^[a-z]+/, "").to_i }.each do |slot|
      transcription[slot].each do |e|
        participant = e.participant
        start = e.start
        stop = e.stop
        text = e.text
        STDERR.puts "PROMBLEM: #{text} in #{file}" unless !e.problem
        xml.sync(:start => start, :stop => stop) do |sync|
          sync.who( :id => participant) do |who|
            xml.text text
          end
        end
      end
    end
  end

  def self.chronology(transcription)
      transcription.keys.sort{ |a,b| a.sub(/^[a-z]+/, "").to_i <=> b.sub(/^[a-z]+/, "").to_i }.each do |slot|
        if transcription[slot].length > 1
          transcription[slot].each do |e|
            e.write
          end
        end
      end
  end


  def self.time_slots=(s)
    @@time_slots[s.attr("TIME_SLOT_ID")] = s.attr("TIME_VALUE")
  end

  def self.time_slots(ref)
    @@time_slots[ref]
  end

  def initialize(filename, doc, order)
    @participants = Hash.new { |h,k| h[k] = {} }
    @sequence = Hash.new
    @sequential = true
    @@time_slots = Hash.new
    @file = filename.sub /^.*\//, ""
    @@chronology[@file] = Hash.new { |h,k| h[k] = [] }
    @author = doc.at_xpath("/*/@AUTHOR").value
    @date = DateTime.parse(doc.at_xpath("/*/@DATE").value)
    @media = doc.xpath( '//MEDIA_DESCRIPTOR/@MEDIA_URL' ).text.sub( /^.+\//, "" ).sub( /\..+$/, "" )
    @time_alignable = Hash.new
    pos = 1
    configured = Annotation.configured?
    doc.xpath('//LINGUISTIC_TYPE').each do |e|
      if e.attr("TIME_ALIGNABLE") == "true"
        if !configured
          Annotation.set_type!(e.attr("LINGUISTIC_TYPE_ID"), 0)
        end
        @time_alignable[e.attr("LINGUISTIC_TYPE_ID")] = true
      else
        if !configured
          Annotation.set_type!(e.attr("LINGUISTIC_TYPE_ID"), pos)
          pos += 1
        end
      end
    end
    slots = doc.xpath('//TIME_ORDER/TIME_SLOT')
    slots.each do |s|

      @@time_slots[s.attr("TIME_SLOT_ID")] = s.attr("TIME_VALUE")
    end
    doc.xpath('//TIER').each do |tier|
      participant = tier.attr('PARTICIPANT')
      linguistic_type_ref = tier.attr("LINGUISTIC_TYPE_REF")
      if @time_alignable[linguistic_type_ref]
        tier.xpath('ANNOTATION').each do |annotation|
          annotation_id = annotation.xpath("ALIGNABLE_ANNOTATION/@ANNOTATION_ID").text
          time_slot_ref1 = annotation.xpath("ALIGNABLE_ANNOTATION/@TIME_SLOT_REF1").text
          time_slot_ref2 = annotation.xpath("ALIGNABLE_ANNOTATION/@TIME_SLOT_REF2").text
          text = annotation.xpath( "ALIGNABLE_ANNOTATION/ANNOTATION_VALUE" ).text
          annotation = Annotation.new(participant, annotation_id, time_slot_ref1, time_slot_ref2, linguistic_type_ref, text)
          @participants[participant][annotation_id] = annotation
          @@chronology[@file][time_slot_ref1].push(annotation)
        end
      else
        tier.xpath('ANNOTATION').each do |annotation|
          annotation_ref = annotation.xpath("REF_ANNOTATION/@ANNOTATION_REF").text
          text = annotation.xpath("REF_ANNOTATION/ANNOTATION_VALUE").text
          @participants[participant][annotation_ref].add(linguistic_type_ref, text)
        end
      end 
    end
  end

  def report
    puts @date
    puts @author
    @time_alignable.each{|e| puts e}
  end

end

if files[0] =~ /\.cnf/
  Transcription::Annotation.init_cqp_cols( File.open( files.shift, "r:utf-8" ).read )
end

files.each do |file|
  f = File.open( file, "r:utf-8" )
  nf = File.open( file + ".vrt", "w:utf-8")
  doc = Nokogiri::XML( f,nil,'UTF-8' )
  f.close
  transcription =  Transcription.new( file, doc, "sequential" )
#  transcriptions.push(transcription)
  
end
puts Transcription.cqp_xml
#Transcription.chronology
#Annotation.problems
#transcriptions.each {|t| t.report}
