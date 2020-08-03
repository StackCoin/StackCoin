class Root < Application
  base "/"

  def index
    respond_with do
      json(nil) # TODO root
      html template("home.ecr")
    end
  end
end
