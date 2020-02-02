module Utils
  # produces a set of indices that correspond to the sorted elements of 'array'
  def self.argsort(array)
    array_map = [] of Bool
    indices = [] of Int32
    array_sorted = array.sort
    (0..array.size).each { |x| array_map << true }

    array_sorted.each do |element|
      array.each_index do |i|
        if array_map[i] && array[i] == element
          indices << i
          array_map[i] = false
        end
      end
    end

    return indices
  end
end
