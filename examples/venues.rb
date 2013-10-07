# Before

def venue_options
  Venue.where(
    foursquare_category_id: foursquare_categories.map(&:id),
    neighborhood_id: neighborhoods.map(&:id)
  )
end

# After

def venues
  Venue.where(
    foursquare_category_id: foursquare_categories.map(&:id),
    neighborhood_id: neighborhoods.map(&:id)
  )
end
