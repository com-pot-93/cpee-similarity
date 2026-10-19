#!/usr/bin/ruby
# encoding: UTF-8

EMBED_CACHE = {}

def embed_cached(text)
  EMBED_CACHE[text] ||= begin
    emb = RagEmbeddings.embed(text, model: "mxbai-embed-large")
    RagEmbeddings::Embedding.from_array(emb)
  end
end

def text_similarity(string1, string2)
  obj1 = embed_cached(string1)
  obj2 = embed_cached(string2)
  return obj1.cosine_similarity(obj2)
end


DIST_CACHE = {}

def text_distance_cached(s, l)
  key = [s, l]
  DIST_CACHE[key] ||= DamerauLevenshtein.array_distance(s, l)
end

def get_model_info(input)
  doc = XML::Smart.string(input)
  doc.register_namespace 'd', 'http://cpee.org/ns/description/1.0'
  tasks = doc.find('//d:call').length
  parallels = doc.find('//d:parallel').length
  decisions = doc.find('//d:choose').length
  loops = doc.find('//d:loop').length
  escapes = doc.find('//d:escape').length
  return [tasks,parallels,decisions,loops,escapes]
end

def update_model_info(arr)
  result = arr.each_with_index.map do |val, i|
    if i == 1 || i == 2
      val * 2
    elsif i == arr.length - 1
      val + 2
    else
      val
    end
  end
  return result
end

def process_model(doc)
  Timeout.timeout(20) do
    model = CPEE::Transformation::Source::CPEE.new(doc)
    trans = CPEE::Transformation::Transformer.new(model)
    traces = trans.build_traces
    all_elements = trans.instance_variable_get(:@source).instance_variable_get(:@graph).instance_variable_get(:@nodes)
    tasks = all_elements.select{|id, node| node.type == :task}.to_h{|id, node| [id, node.label]}
    return traces, tasks
  end
rescue Timeout::Error => e
  pp "model is impossible to parse. #{path}"
  raise e
end

def create_sim_matrix(short,long)
  pp "similarity"
  sim_matrix = []
  short.each do |fid,flab|
    temp = []
    long.each do |lid,llab|
      temp << text_similarity(flab, llab)
    end
    sim_matrix << temp
  end
  return sim_matrix
end

def create_lev_matrix(nshort,nlong)
  lev_matrix = []
  nshort.each do |s|
    temp = []
    nlong.each do |l|
      #pp "#{s} x #{l}"
      temp << text_distance_cached(s,l)
      #pp  text_distance_cached(s,l)
    end
    lev_matrix << temp
  end
  return lev_matrix
end

def make_square_matrix(omatrix, dummy_value = 0)
  matrix = omatrix.map(&:dup)
  # Number of rows and columns
  rows = matrix.length
  cols = matrix[0].length

  # Pad with dummy rows if rows < cols
  if rows < cols
    (cols - rows).times { matrix << Array.new(cols, dummy_value) }
  elsif rows > cols
    diff = rows - cols
    matrix.each { |row| row.concat(Array.new(diff, dummy_value)) }
  end
  return matrix
end

def control_flow_penalty(input1,input2)
  fel = get_model_info(input1)
  lel = get_model_info(input2)
  a = update_model_info(fel)
  b = update_model_info(lel)
  number_all_elements = a.sum + b.sum
  number_diff_elements = a[1..-1].zip(b[1..-1]).sum { |x, y| (x - y).abs }
  penalty = number_diff_elements.to_f/number_all_elements
  return penalty
end

