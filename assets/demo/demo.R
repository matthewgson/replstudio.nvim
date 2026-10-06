# %% load
library(ggplot2)
cars <- transform(mtcars, cyl = factor(cyl))

# %% model + plots
slope <- function(df) {
  fit <- lm(mpg ~ wt, data = df)

  coef(fit)[["wt"]]
}
slope(cars)

ggplot(cars, aes(wt, mpg, colour = cyl)) +
  geom_point(size = 3) +
  geom_smooth(method = "lm", formula = y ~ x, se = FALSE) +
  labs(title = "Fuel economy vs weight")

ggplot(cars, aes(cyl, hp, fill = cyl)) +
  geom_boxplot() +
  labs(title = "Horsepower by cylinders")
