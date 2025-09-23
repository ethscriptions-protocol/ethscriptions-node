class Integer
  def ether
    (self.to_d * 1e18.to_d).to_i
  end
  
  def gwei
    (self.to_d * 1e9.to_d).to_i
  end
end

class Float
  def ether
    (self.to_d * 1e18.to_d).to_i
  end
  
  def gwei
    (self.to_d * 1e9.to_d).to_i
  end
end

class String
  def pbcopy(strip: true)
    to_copy = strip ? self.strip : self
    Clipboard.copy(to_copy)
    nil
  end
end
