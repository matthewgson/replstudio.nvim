# %% data
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from plotnine import aes, geom_point, geom_smooth, ggplot, labs

rng = np.random.default_rng(0)
df = pd.DataFrame({"x": rng.normal(size=200)})
df["y"] = 2 * df["x"] + rng.normal(size=200)

# %% plots
fig, ax = plt.subplots()
ax.hist(df["y"], bins=30, color="steelblue")
ax.set_title("Distribution of y (matplotlib)")

p = (
    ggplot(df, aes("x", "y"))
    + geom_point(alpha=0.6)
    + geom_smooth(method="lm", color="red")
    + labs(title="y vs x (plotnine)")
)
p.show()
